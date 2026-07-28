import { DOCX_MIME, PDF_MIME } from "./common.ts";
import { RagError } from "./errors.ts";

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
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n")
    .replace(/\n{4,}/g, "\n\n\n")
    .trim();
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
      extractionVersion: "1.8.0",
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
