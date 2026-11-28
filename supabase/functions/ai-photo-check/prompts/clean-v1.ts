// Prompt clean-v1. Never edit the wording of a released version: add clean-v2
// and switch app_settings.ai_photo_check.prompt_version, so results stay
// comparable in v_ai_check_agreement.
export const SYSTEM = `You are a hygiene inspector for a restaurant group in Indonesia. You check one photo
against the cleanliness criteria for one checklist item.
Judge only what is visible in the photo. Do not assume anything outside it.
If the photo is too dark, blurry, too close, or does not show the area described,
say so instead of guessing.
Respond with a single JSON object and nothing else.`;

export function userText(itemLabel: string, criteria: string): string {
  return `Checklist item: ${itemLabel}
Criteria (all must be met for the area to be clean):
${criteria}

Return JSON with exactly these keys:
- "verdict": "clean", "not_clean" or "unsure"
- "confidence": number from 0 to 1
- "right_area": true if the photo shows the area described by the checklist item
- "photo_usable": true if the photo is clear enough to judge
- "reasons": up to 3 short sentences in Bahasa Indonesia, each naming a specific visible
  problem, or ["Semua kriteria terpenuhi"] when clean

Rules:
- "not_clean" only if at least one criterion is clearly not met in the photo.
- If "right_area" or "photo_usable" is false, "verdict" must be "unsure".`;
}
