/**
 * Scores a prompt against a skill using keyword and name matching.
 * Returns a confidence score between 0 and 1.
 */
function scoreSkill(prompt, skill) {
  const text = prompt.toLowerCase();
  let score = 0;
  let matches = 0;
  let total = 0;

  // Check skill name
  total++;
  if (text.includes(skill.name.toLowerCase())) {
    score += 0.9;
    matches++;
  }

  // Check keywords
  for (const kw of skill.keywords) {
    total++;
    if (text.includes(kw.toLowerCase())) {
      score += 0.7;
      matches++;
    }
  }

  // Check examples (partial match)
  for (const ex of skill.examples) {
    const exWords = ex.toLowerCase().split(/\s+/).filter(w => w.length > 3);
    const matchedWords = exWords.filter(w => text.includes(w));
    if (matchedWords.length > 0 && exWords.length > 0) {
      total++;
      score += 0.5 * (matchedWords.length / exWords.length);
      matches++;
    }
  }

  if (total === 0) return 0;
  // Normalize: max possible score per item varies, cap at 1.0
  return Math.min(score / Math.max(total, 1), 1.0);
}

/**
 * Computes cosine similarity between two Float32Array vectors.
 * Result is clamped to [0, 1].
 */
function cosineSimilarity(a, b) {
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  if (denom === 0) return 0;
  return Math.max(0, Math.min(1, dot / denom));
}

/**
 * Finds the best matching skill for a prompt.
 * Blends keyword score with semantic cosine similarity when embeddings are available.
 * Returns { skill, confidence } or null if no match above threshold.
 */
export function findBestMatch(prompt, skillIndex, threshold = 0.75, promptEmbedding = null) {
  let best = null;
  let bestScore = 0;

  for (const skill of skillIndex) {
    const keywordScore = scoreSkill(prompt, skill);
    let finalScore = keywordScore;

    if (promptEmbedding !== null && skill.embedding !== null) {
      const semanticScore = cosineSimilarity(promptEmbedding, skill.embedding);
      finalScore = 0.4 * keywordScore + 0.6 * semanticScore;
    }

    if (finalScore > bestScore) {
      bestScore = finalScore;
      best = skill;
    }
  }

  if (best && bestScore >= threshold) {
    return { skill: best, confidence: bestScore };
  }
  return null;
}
