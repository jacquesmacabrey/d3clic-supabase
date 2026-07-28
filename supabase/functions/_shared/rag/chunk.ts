import { RagError } from "./errors.ts";
import type { ExtractedDocument, ExtractedSegment } from "./extract.ts";

const TARGET_CHARACTERS = 4_000;
const OVERLAP_CHARACTERS = 500;
const MIN_BREAK_RATIO = 0.62;
const MAX_CHUNKS = 800;

export interface PassageDraft {
  chunkIndex: number;
  content: string;
  pageStart: number | null;
  pageEnd: number | null;
  sectionTitle: string | null;
  articleReference: string | null;
  sourceReference: string;
  metadata: Record<string, unknown>;
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

function headingCandidates(text: string): string[] {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length >= 3 && line.length <= 140);
}

function looksLikeHeading(line: string): boolean {
  if (
    /^(titre|chapitre|section|sous-section|annexe)\b/i.test(line) ||
    /^(?:[0-9]+(?:\.[0-9]+){0,4}|[IVXLCDM]+)\s*[-–—.)]\s+\S/i.test(line)
  ) {
    return true;
  }
  const letters = [...line].filter((char) => /\p{L}/u.test(char));
  return letters.length >= 4 &&
    letters.every((char) => char === char.toLocaleUpperCase("fr-CH"));
}

function detectHeading(text: string): string | null {
  const line = headingCandidates(text).find(looksLikeHeading);
  return line?.slice(0, 250) ?? null;
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

  extracted.segments.forEach((segment, segmentIndex) => {
    let currentHeading: string | null = null;
    const segmentChunks = splitText(segment.text);
    segmentChunks.forEach((content, segmentChunkIndex) => {
      currentHeading = detectHeading(content) ?? currentHeading;
      const chunkIndex = passages.length;
      passages.push({
        chunkIndex,
        content,
        pageStart: segment.pageStart,
        pageEnd: segment.pageEnd,
        sectionTitle: currentHeading,
        articleReference: detectArticle(content),
        sourceReference: buildSourceReference(title, segment, chunkIndex),
        metadata: {
          extraction_segment_index: segmentIndex,
          extraction_segment_chunk_index: segmentChunkIndex,
          character_count: content.length,
          overlap_characters: segmentChunkIndex > 0 ? OVERLAP_CHARACTERS : 0,
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

  if (passages.length === 0) {
    throw new RagError(
      "no_passages",
      "Aucun passage exploitable n'a pu être créé.",
      422,
    );
  }
  return passages;
}
