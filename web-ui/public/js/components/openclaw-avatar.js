// OpenClaw Avatar Component - PNG image-based emotion avatar

const EMOTION_LABELS = {
  happy: '嬉しい',
  sad: '悲しい',
  angry: '怒り',
  surprised: '驚き',
  thinking: '考え中...',
  concerned: '心配...',
  satisfied: '達成感',
  neutral: '通常'
};

export function renderAvatar(emotion) {
  const key = EMOTION_LABELS[emotion] ? emotion : 'neutral';
  return `<div class="openclaw-avatar avatar-${key}">
    <img src="/img/emotions/${key}.png" alt="${getEmotionLabel(key)}" width="80" height="80" />
  </div>`;
}

export function getEmotionLabel(emotion) {
  return EMOTION_LABELS[emotion] || EMOTION_LABELS.neutral;
}
