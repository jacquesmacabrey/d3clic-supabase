import { RagError } from "./errors.ts";
import type { ExtractedDocument, ExtractedSegment } from "./extract.ts";

export const TARGET_CHARACTERS = 4_000;
export const OVERLAP_CHARACTERS = 500;
const MIN_BREAK_RATIO = 0.62;
const MAX_CHUNKS = 800;
const TOKEN_COUNT_METHOD = "estimated_utf8_bytes_div_4";

export interface PassageDraft {
  chunkIndex: number;
  content: string;
  tokenCount: number;
  pageStart: number | null;
  pageEnd: number | null;
  sectionTitle: string | null;
  articleReference: string | null;
  sourceReference: string;
  metadata: Record<string, unknown>;
}

type HeadingKind =
  | "explicit"
  | "article"
  | "hierarchical_number"
  | "numbered"
  | "roman"
  | "uppercase";

interface DetectedHeading {
  title: string;
  kind: HeadingKind;
  confidence: number;
}

interface StructuralBlock {
  text: string;
  heading: DetectedHeading | null;
  sourceIndex: number;
  listFragmentIndex: number | null;
}

function preferredBreak(window: string): number {
  const minimum = Math.floor(TARGET_CHARACTERS * MIN_BREAK_RATIO);
  const candidates = [
    window.lastIndexOf("\n\n"),
    window.lastIndexOf("\n"),
    window.lastIndexOf(". "),
    window.lastIndexOf("; "),
    window.lastIndexOf(", "),
    window.lastIndexOf(" "),
  ];
  return candidates.find((index) => index >= minimum) ?? -1;
}

function splitText(text: string): string[] {
  if (text.length <= TARGET_CHARACTERS) return [text.trim()];

  const chunks: string[] = [];
  let start = 0;
  while (start < text.length) {
    const hardEnd = Math.min(start + TARGET_CHARACTERS, text.length);
    let end = hardEnd;
    if (hardEnd < text.length) {
      const window = text.slice(start, hardEnd);
      const breakAt = preferredBreak(window);
      if (breakAt >= 0) end = start + breakAt + 1;
    }

    const chunk = text.slice(start, end).trim();
    if (chunk) chunks.push(chunk);
    if (end >= text.length) break;

    const nextStart = Math.max(start + 1, end - OVERLAP_CHARACTERS);
    start = nextStart;
    while (start < text.length && /\s/.test(text[start])) start += 1;
  }
  return chunks;
}

function detectArticle(text: string): string | null {
  const match = text.match(
    /^(?:article|art\.)\s*[0-9]+(?:[a-z]|(?:\.[0-9]+)*)?(?:\s*[-–—:][^\n]{0,120})?/im,
  );
  return match?.[0]?.trim().slice(0, 160) ?? null;
}

function cleanLine(line: string): string {
  return line.replace(/\s+/g, " ").trim();
}

function isTerminalListItem(line: string): boolean {
  return /[;,]$/.test(line);
}

const LETTERED_LIST_ITEM_PATTERN = /^[a-zà-öø-ÿ]\s*[-–—.)]\s+\S/u;

function detectHeading(lineValue: string): DetectedHeading | null {
  const line = cleanLine(lineValue);
  if (line.length < 3 || line.length > 140) return null;

  // Lowercase lettered items such as "a) ...", "b) ..." and "c) ..." are
  // deliberately not treated as headings. In legal and HR documents they are
  // much more often list items than structural titles.
  if (LETTERED_LIST_ITEM_PATTERN.test(line)) return null;

  if (
    /^(?:titre|chapitre|section|sous-section|partie|livre|annexe|appendice)\b/iu
      .test(line)
  ) {
    return { title: line, kind: "explicit", confidence: 1 };
  }

  if (/^(?:article|art\.)\s*\d+(?:[a-z]|(?:\.\d+)*)?\b/iu.test(line)) {
    return { title: line, kind: "article", confidence: 1 };
  }

  if (/^\d+(?:\.\d+){1,5}\s+\p{Lu}\S*/u.test(line)) {
    return {
      title: line,
      kind: "hierarchical_number",
      confidence: 0.99,
    };
  }

  if (
    /^\d{1,3}(?:\.\d+){0,4}\s*[-–—.)]\s+\p{Lu}\S*/u.test(line) &&
    !isTerminalListItem(line)
  ) {
    return { title: line, kind: "numbered", confidence: 0.97 };
  }

  // Some regulations use "5 Evaluation demandée..." without a dot after the
  // number. Requiring an uppercase first letter and no list punctuation avoids
  // classifying ordinary numeric sentences as headings.
  const unpunctuatedNumbered = line.match(
    /^\d{1,3}\s+(\p{Lu}[\p{L}\d'’ -]*)$/u,
  );
  if (unpunctuatedNumbered && !/[.;,:!?]$/.test(line)) {
    const candidateText = unpunctuatedNumbered[1];
    const looksLikeSentence = /^(?:le|la|les|l['’]|un|une|des|du|il|elle|ils|elles|ce|cet|cette|ces|lorsque|lorsqu['’]|si)\b/iu
      .test(candidateText);
    if (!looksLikeSentence) {
      return { title: line, kind: "numbered", confidence: 0.93 };
    }
  }

  if (
    /^[IVXLCDM]{1,8}\s*[-–—.)]\s+\p{Lu}\S*/u.test(line) &&
    !isTerminalListItem(line)
  ) {
    return { title: line, kind: "roman", confidence: 0.96 };
  }

  const letters = [...line].filter((char) => /\p{L}/u.test(char));
  if (
    letters.length >= 4 &&
    letters.every((char) => char === char.toLocaleUpperCase("fr-CH")) &&
    !isTerminalListItem(line)
  ) {
    return { title: line, kind: "uppercase", confidence: 0.9 };
  }

  return null;
}

function splitIntoStructuralBlocks(text: string): StructuralBlock[] {
  const blocks: StructuralBlock[] = [];
  let lines: string[] = [];
  let heading: DetectedHeading | null = null;

  const flush = () => {
    const content = lines.join("\n").trim();
    if (content) {
      blocks.push({
        text: content,
        heading,
        sourceIndex: blocks.length,
        listFragmentIndex: null,
      });
    }
    lines = [];
    heading = null;
  };

  for (const rawLine of text.split(/\r?\n/)) {
    const detected = detectHeading(rawLine);
    if (detected) {
      flush();
      heading = detected;
      lines.push(rawLine.trim());
      continue;
    }
    lines.push(rawLine);
  }
  flush();

  return blocks;
}

function isListBoundaryLine(lineValue: string): boolean {
  const line = cleanLine(lineValue);
  // Contrairement à un titre, une clause de liste (« c) décès d'un parent
  // ou allié au 2e degré : 2 jours (grands-parents, ...) ») peut
  // légitimement dépasser largement la longueur d'un titre — seule une
  // borne minimale est nécessaire ici, pour éviter de réagir à une ligne
  // vide ou à du bruit d'extraction.
  if (line.length < 3) return false;
  return LETTERED_LIST_ITEM_PATTERN.test(line);
}

/**
 * A lettered list item ("a) ...", "b) ...") is deliberately never treated
 * as a heading (see detectHeading above) because in legal and HR documents
 * it is far more often a list item than a structural title. Left
 * unhandled, a whole list of lettered items under the same heading stays
 * a single passage — which risks wrongly protecting unrelated items that
 * share that passage once one of them backs a validated numeric rule
 * (see RAG-10.1.1). This step creates a passage boundary at each lettered
 * item without ever touching `heading`, so `sectionTitle` stays identical
 * across every resulting fragment — only the passage boundaries change.
 */
function splitBlockByListBoundaries(
  block: StructuralBlock,
): StructuralBlock[] {
  const lines = block.text.split(/\r?\n/);
  const fragments: string[][] = [];
  let current: string[] = [];

  for (const rawLine of lines) {
    if (isListBoundaryLine(rawLine) && current.length > 0) {
      fragments.push(current);
      current = [];
    }
    current.push(rawLine);
  }
  if (current.length > 0) fragments.push(current);

  if (fragments.length <= 1) return [block];

  return fragments.map((fragmentLines, fragmentIndex) => ({
    text: fragmentLines.join("\n").trim(),
    heading: block.heading,
    sourceIndex: block.sourceIndex,
    listFragmentIndex: fragmentIndex,
  }));
}


interface SequenceHeading {
  family: string;
  number: number;
}

interface NumberedSection {
  sequenceNumber: number;
  blocks: StructuralBlock[];
}

function simpleSequenceHeading(
  heading: DetectedHeading | null,
): SequenceHeading | null {
  if (!heading) return null;

  const patterns: Array<{ family: string; expression: RegExp }> = [
    { family: "article", expression: /^(?:article|art\.)\s*(\d+)\b/iu },
    {
      family: "explicit_number",
      expression:
        /^(?:titre|chapitre|section|partie|livre|annexe|appendice)\s+(\d+)\b/iu,
    },
    {
      family: "numbered",
      expression: /^(\d+)(?:\s*[-–—.)]\s+|\s+\p{Lu})/u,
    },
  ];

  const allowedFamilies = heading.kind === "article"
    ? ["article"]
    : heading.kind === "explicit"
    ? ["explicit_number"]
    : heading.kind === "numbered"
    ? ["numbered"]
    : [];

  for (const pattern of patterns) {
    if (!allowedFamilies.includes(pattern.family)) continue;
    const match = heading.title.match(pattern.expression);
    if (!match) continue;
    const value = Number(match[1]);
    if (Number.isSafeInteger(value) && value > 0) {
      return { family: pattern.family, number: value };
    }
  }
  return null;
}

/**
 * Word text boxes are sometimes exposed by Mammoth in XML/anchor order rather
 * than in logical reading order. Reordering is deliberately conservative:
 * every detected top-level heading must belong to the same family, have a
 * unique integer number and form a consecutive set. Documents with gaps,
 * suffixes, duplicate numbering or restarted annex numbering keep their
 * extracted order.
 */
function normalizeConsecutiveHeadingOrder(
  blocks: StructuralBlock[],
): StructuralBlock[] {
  const firstNumberedIndex = blocks.findIndex((block) =>
    simpleSequenceHeading(block.heading) !== null
  );
  if (firstNumberedIndex < 0) return blocks;

  const prefix = blocks.slice(0, firstNumberedIndex);
  const firstSequence = simpleSequenceHeading(
    blocks[firstNumberedIndex].heading,
  );
  if (!firstSequence) return blocks;

  const sections: NumberedSection[] = [];
  let current: NumberedSection | null = null;

  for (const block of blocks.slice(firstNumberedIndex)) {
    const sequence = simpleSequenceHeading(block.heading);
    if (sequence?.family === firstSequence.family) {
      current = { sequenceNumber: sequence.number, blocks: [block] };
      sections.push(current);
    } else if (current) {
      current.blocks.push(block);
    } else {
      return blocks;
    }
  }

  if (sections.length < 3) return blocks;
  const numbers = sections.map((section) => section.sequenceNumber);
  const unique = new Set(numbers);
  if (unique.size !== numbers.length) return blocks;

  const sortedNumbers = [...numbers].sort((a, b) => a - b);
  for (let index = 1; index < sortedNumbers.length; index += 1) {
    if (sortedNumbers[index] !== sortedNumbers[index - 1] + 1) return blocks;
  }

  const alreadyOrdered = numbers.every((value, index) =>
    value === sortedNumbers[index]
  );
  if (alreadyOrdered) return blocks;

  const orderedSections = [...sections].sort((a, b) =>
    a.sequenceNumber - b.sequenceNumber
  );
  return [
    ...prefix,
    ...orderedSections.flatMap((section) => section.blocks),
  ];
}

function estimateTokenCount(content: string): number {
  const utf8Bytes = new TextEncoder().encode(content).length;
  return Math.max(1, Math.ceil(utf8Bytes / 4));
}

function buildSourceReference(
  title: string,
  segment: ExtractedSegment,
  chunkIndex: number,
): string {
  const cleanTitle = title.trim().slice(0, 250);
  if (segment.pageStart !== null) {
    const pageLabel = segment.pageEnd !== null &&
        segment.pageEnd !== segment.pageStart
      ? `pages ${segment.pageStart}–${segment.pageEnd}`
      : `page ${segment.pageStart}`;
    return `${cleanTitle} — ${pageLabel}`.slice(0, 500);
  }
  return `${cleanTitle} — passage ${chunkIndex + 1}`.slice(0, 500);
}

export function chunkDocument(
  extracted: ExtractedDocument,
  title: string,
): PassageDraft[] {
  const passages: PassageDraft[] = [];
  let currentHeading: DetectedHeading | null = null;

  extracted.segments.forEach((segment, segmentIndex) => {
    const detectedBlocks = splitIntoStructuralBlocks(segment.text);
    const orderedBlocks = extracted.extractionMethod === "mammoth"
      ? normalizeConsecutiveHeadingOrder(detectedBlocks)
      : detectedBlocks;
    const structuralBlocks = orderedBlocks.flatMap((block) =>
      splitBlockByListBoundaries(block)
    );
    structuralBlocks.forEach((block, structuralBlockIndex) => {
      if (block.heading) currentHeading = block.heading;

      // A heading alone carries the structure to the following block/page but
      // does not create a tiny, low-value passage.
      if (
        block.heading &&
        cleanLine(block.text) === block.heading.title
      ) {
        return;
      }

      const blockChunks = splitText(block.text);
      blockChunks.forEach((content, blockChunkIndex) => {
        const chunkIndex = passages.length;
        passages.push({
          chunkIndex,
          content,
          tokenCount: estimateTokenCount(content),
          pageStart: segment.pageStart,
          pageEnd: segment.pageEnd,
          sectionTitle: currentHeading?.title ?? null,
          articleReference: detectArticle(content),
          sourceReference: buildSourceReference(title, segment, chunkIndex),
          metadata: {
            extraction_segment_index: segmentIndex,
            extraction_structural_block_index: block.sourceIndex,
            normalized_structural_block_index: structuralBlockIndex,
            extraction_block_chunk_index: blockChunkIndex,
            character_count: content.length,
            token_count_method: TOKEN_COUNT_METHOD,
            overlap_characters: blockChunkIndex > 0 ? OVERLAP_CHARACTERS : 0,
            structural_order_normalized:
              block.sourceIndex !== structuralBlockIndex,
            list_fragment_index: block.listFragmentIndex,
            section_heading_source: block.heading ? "detected" : currentHeading
              ? "carried"
              : "none",
            section_heading_kind: currentHeading?.kind ?? null,
            section_heading_confidence: currentHeading?.confidence ?? null,
          },
        });
        if (passages.length > MAX_CHUNKS) {
          throw new RagError(
            "too_many_passages",
            `Le document produit plus de ${MAX_CHUNKS} passages.`,
            400,
          );
        }
      });
    });
  });

  if (passages.length === 0) {
    throw new RagError(
      "no_passages",
      "Aucun passage exploitable n'a pu être créé.",
      422,
    );
  }
  return passages;
}
