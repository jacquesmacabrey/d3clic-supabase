import { DOCX_MIME, PDF_MIME } from "./common.ts";
import { RagError } from "./errors.ts";
import { unzipSync } from "npm:fflate@0.8.3";

const MAX_PDF_PAGES = 250;
const MAX_EXTRACTED_CHARACTERS = 1_500_000;

export interface ExtractedSegment {
  text: string;
  pageStart: number | null;
  pageEnd: number | null;
}

export interface ExtractedDocument {
  segments: ExtractedSegment[];
  pageCount: number | null;
  characterCount: number;
  extractionMethod: string;
  extractionVersion: string;
}

function normalizeText(input: string): string {
  return input
    .replace(/\u0000/g, "")
    .replace(/\u000b/g, "\n")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u00a0\u202f]/g, " ")
    .replace(/[\uf0a7\uf0b7\uf0d8\uf0fc][\uf020 \t]*/gu, "• ")
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trimEnd())
    .join("\n")
    .replace(/\n{4,}/g, "\n\n\n")
    .trim();
}

const DOCX_COMPLEX_LAYOUT_MESSAGE =
  "Ce document Word utilise une mise en page complexe que nous ne pouvons pas lire de manière suffisamment fiable. Ouvre-le dans Word, choisis « Enregistrer sous », sélectionne le format PDF, puis importe ce PDF.";

function hasMultipleColumns(xml: string): boolean {
  const columnDefinitions = xml.match(
    /<w:cols\b[^>]*(?:\/>|>[\s\S]*?<\/w:cols>)/giu,
  ) ?? [];

  return columnDefinitions.some((definition) => {
    const declaredCount = definition.match(
      /\bw:num\s*=\s*["'](\d+)["']/iu,
    );

    if (declaredCount && Number(declaredCount[1]) > 1) {
      return true;
    }

    const explicitColumns = definition.match(/<w:col\b/giu) ?? [];
    return explicitColumns.length > 1;
  });
}

function validateDocxStructure(bytes: Uint8Array): void {
  let hasComplexPackagePart = false;
  let archive: Record<string, Uint8Array>;

  try {
    archive = unzipSync(bytes, {
      filter: (file) => {
        const name = file.name.replace(/\\/g, "/");

        if (/^word\/(?:charts|diagrams|embeddings)\//iu.test(name)) {
          hasComplexPackagePart = true;
        }

        return name === "word/document.xml";
      },
    });
  } catch {
    throw new RagError(
      "docx_extraction_failed",
      "Le document Word est protégé, corrompu ou illisible.",
      422,
    );
  }

  const documentXmlBytes = archive["word/document.xml"];

  if (!documentXmlBytes) {
    throw new RagError(
      "docx_extraction_failed",
      "Le document Word est protégé, corrompu ou illisible.",
      422,
    );
  }

  const xml = new TextDecoder().decode(documentXmlBytes);

  const hasTextBox =
    /<(?:w:txbxContent|v:textbox|wps:txbx)\b/iu.test(xml);

  const hasComplexXmlObject =
    /<(?:w:object|w:control|w:altChunk|o:OLEObject|dgm:relIds|c:chart)\b/iu
      .test(xml);

  if (
    hasTextBox ||
    hasMultipleColumns(xml) ||
    hasComplexPackagePart ||
    hasComplexXmlObject
  ) {
    throw new RagError(
      "docx_complex_layout",
      DOCX_COMPLEX_LAYOUT_MESSAGE,
      422,
    );
  }
}

async function extractPdf(bytes: Uint8Array): Promise<ExtractedDocument> {
  try {
    const { getDocumentProxy, extractText } = await import("npm:unpdf@1.3.2");
    const pdf = await getDocumentProxy(bytes);
    const pageCount = Number(pdf.numPages ?? 0);
    if (!Number.isInteger(pageCount) || pageCount < 1) {
      throw new RagError(
        "pdf_invalid",
        "Le PDF est vide ou invalide.",
        400,
      );
    }
    if (pageCount > MAX_PDF_PAGES) {
      throw new RagError(
        "document_too_large",
        `Le PDF dépasse la limite de ${MAX_PDF_PAGES} pages.`,
        400,
      );
    }

    const result = await extractText(pdf, { mergePages: false });
    const pages = Array.isArray(result.text)
      ? result.text.map((page) => String(page ?? ""))
      : [String(result.text ?? "")];

    let characterCount = 0;
    const segments: ExtractedSegment[] = [];
    for (let index = 0; index < pages.length; index += 1) {
      const text = normalizeText(pages[index]);
      if (!text) continue;
      characterCount += text.length;
      if (characterCount > MAX_EXTRACTED_CHARACTERS) {
        throw new RagError(
          "document_too_large",
          "Le texte extrait dépasse la limite autorisée.",
          400,
        );
      }
      segments.push({
        text,
        pageStart: index + 1,
        pageEnd: index + 1,
      });
    }

    if (segments.length === 0) {
      throw new RagError(
        "no_usable_text",
        "Aucun texte exploitable n'a été trouvé. Les PDF scannés sans couche texte ne sont pas encore pris en charge.",
        422,
      );
    }

    return {
      segments,
      pageCount,
      characterCount,
      extractionMethod: "unpdf",
      extractionVersion: "1.3.2",
    };
  } catch (error) {
    if (error instanceof RagError) throw error;
    throw new RagError(
      "pdf_extraction_failed",
      "Le PDF est protégé, corrompu ou illisible.",
      422,
    );
  }
}

async function extractDocx(bytes: Uint8Array): Promise<ExtractedDocument> {
  try {
    validateDocxStructure(bytes);
    const module = await import("npm:mammoth@1.8.0");
    const mammoth = module as unknown as {
      default?: {
        extractRawText: (
          input: { buffer: ArrayBuffer },
        ) => Promise<{ value: string }>;
      };
      extractRawText?: (
        input: { buffer: ArrayBuffer },
      ) => Promise<{ value: string }>;
    };
    const extractRawText = mammoth.extractRawText ??
      mammoth.default?.extractRawText;
    if (!extractRawText) {
      throw new Error("mammoth_extractRawText_missing");
    }

    const { value } = await extractRawText({ buffer: bytes.slice().buffer });
    const text = normalizeText(value ?? "");
    if (!text) {
      throw new RagError(
        "no_usable_text",
        "Aucun texte exploitable n'a été trouvé dans le document Word.",
        422,
      );
    }
    if (text.length > MAX_EXTRACTED_CHARACTERS) {
      throw new RagError(
        "document_too_large",
        "Le texte extrait dépasse la limite autorisée.",
        400,
      );
    }

    return {
      segments: [{ text, pageStart: null, pageEnd: null }],
      pageCount: null,
      characterCount: text.length,
      extractionMethod: "mammoth",
      extractionVersion: "1.8.0/d3clic-normalize-2",
    };
  } catch (error) {
    if (error instanceof RagError) throw error;
    throw new RagError(
      "docx_extraction_failed",
      "Le document Word est protégé, corrompu ou illisible.",
      422,
    );
  }
}

export async function extractDocument(
  bytes: Uint8Array,
  mimeType: string,
): Promise<ExtractedDocument> {
  if (!bytes.length) {
    throw new RagError("empty_file", "Le fichier est vide.", 400);
  }
  if (mimeType === PDF_MIME) return extractPdf(bytes);
  if (mimeType === DOCX_MIME) return extractDocx(bytes);
  throw new RagError(
    "unsupported_format",
    "Format non autorisé.",
    400,
  );
}
