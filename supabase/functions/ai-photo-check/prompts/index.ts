import * as cleanV1 from "./clean-v1.ts";

export type Prompt = {
  SYSTEM: string;
  userText: (itemLabel: string, criteria: string) => string;
};

export const PROMPTS: Record<string, Prompt> = {
  "clean-v1": cleanV1,
};
