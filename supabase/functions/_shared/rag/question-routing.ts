import {
  type PublicDeterministicAnswer,
  questionTargetsAnnualLeave,
} from "./deterministic-rules.ts";

export const GENERIC_LEAVE_CLARIFICATION =
  "De quel type de congé parles-tu : vacances annuelles, maladie, maternité ou paternité, décès, proche malade, ou autre situation ?";
export const BEREAVEMENT_RELATIONSHIP_CLARIFICATION =
  "Quel est ton lien avec la personne décédée ?";

function normalize(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[’`´]/g, "'")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function requestsLeaveOverview(text: string): boolean {
  const overview =
    "(?:types?|liste|differents?|categories?|lesquels?|inventaire|existe(?:nt)?)";
  return new RegExp(
    `(?:\\b${overview}\\b.*\\bconges?\\b|\\bconges?\\b.*\\b${overview}\\b)`,
  ).test(text);
}

/*
  Une expression comme « week-ends de congé », « indemnité de congé » ou
  « procédure de congé » contient déjà un objet documentaire précis. Elle ne
  doit pas être réduite au seul mot « congé ».

  Les unités génériques ci-dessous ne qualifient pas le congé : « combien de
  jours de congé » reste donc une demande ambiguë.
*/
function hasSpecifiedLeaveObject(text: string): boolean {
  const genericMeasurements = new Set([
    "droit",
    "droits",
    "duree",
    "heure",
    "heures",
    "jour",
    "journee",
    "journees",
    "jours",
    "mois",
    "nombre",
    "quantite",
    "semaine",
    "semaines",
    "temps",
  ]);

  for (
    const match of text.matchAll(
      /\b([\p{L}-]+)\s+de\s+conges?\b/gu,
    )
  ) {
    if (!genericMeasurements.has(match[1])) return true;
  }
  return false;
}

function hasDocumentaryLeaveQualifier(text: string): boolean {
  const knownType =
    /\b(?:adoption|allaitement|deces|deuil|deménagement|demenagement|enfant|extraordinaire|familial|formation|grossesse|jeunesse|malade|maladie|mariage|maternite|medical|militaire|naissance|parental|paternite|proche|sabbatique|service civil|sans solde|special)\b/;
  if (knownType.test(text)) return true;

  // Une formulation comme « congé pour un examen professionnel » désigne
  // déjà un motif, même si ce motif n'est pas dans la liste ci-dessus.
  return /\bconges?\s+(?:(?:de|pour)\s+|(?:en cas|lors|suite)\s+de\s+|lie\s+a\s+)(?:(?:un|une|le|la|les|du|des|l')\s+)?\p{L}{3,}/u
    .test(text);
}

function asksForPersonalLeaveEntitlement(text: string): boolean {
  if (
    /\b(?:combien|droit|duree|jours?|semaines?|prendre|obtenir|quel)\b/.test(
      text,
    )
  ) {
    return true;
  }
  return text.split(/\s+/).length <= 4;
}

function targetsBereavementLeave(text: string): boolean {
  return (
    /\bconges?\b/.test(text) &&
    /\b(?:deces|deuil)\b/.test(text) &&
    asksForPersonalLeaveEntitlement(text)
  );
}

/*
  Une relation concrète suffit pour poursuivre la recherche documentaire.
  La liste ne préjuge d'aucun droit : elle distingue seulement une relation
  nommée d'expressions indéterminées comme « un proche » ou
  « un membre de ma famille ».
*/
function hasSpecificBereavementRelationship(text: string): boolean {
  const knownRelationship =
    /\b(?:ami|amie|beau-frere|beau-pere|belle-mere|belle-soeur|collegue|compagnon|compagne|conjoint|conjointe|cousin|cousine|enfant|epoux|epouse|femme|fille|fils|frere|grand-mere|grand-parent|grand-pere|maman|mari|mere|neveu|niece|oncle|papa|parent|partenaire|pere|soeur|tante)\b/;
  const namedPossessiveRelationship =
    /\b(?:mon|ma|mes|notre|nos)\s+(?!(?:famille|membre|personne|proche|proches)\b)\p{L}[\p{L}-]*/u;
  return knownRelationship.test(text) || namedPossessiveRelationship.test(text);
}

/*
  Ce routeur ne suppose ni document, ni convention collective. Il intercepte
  seulement deux ambiguïtés factuelles avant la recherche :
  - le type d'un congé non précisé ;
  - le lien avec la personne décédée lorsqu'il n'est pas nommé.

  Il ne déduit jamais un droit ni une durée. Une fois le fait précisé, la
  question consolidée poursuit le parcours documentaire normal.
*/
export function routeGenericLeaveQuestion(
  question: string,
): PublicDeterministicAnswer | null {
  const text = normalize(question);
  if (!/\bconges?\b/.test(text)) return null;
  if (questionTargetsAnnualLeave(question)) return null;
  if (requestsLeaveOverview(text)) return null;
  if (hasSpecifiedLeaveObject(text)) return null;
  if (
    targetsBereavementLeave(text) &&
    !hasSpecificBereavementRelationship(text)
  ) {
    return {
      result: "needs_clarification",
      answer: BEREAVEMENT_RELATIONSHIP_CLARIFICATION,
      needs_human_review: false,
    };
  }
  if (hasDocumentaryLeaveQualifier(text)) return null;
  if (!asksForPersonalLeaveEntitlement(text)) return null;

  return {
    result: "needs_clarification",
    answer: GENERIC_LEAVE_CLARIFICATION,
    needs_human_review: false,
  };
}
