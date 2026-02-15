// OpenClaw Avatar Component - SVG-based emotion avatar

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

const EMOTION_TO_STATE = {
  happy: 'happy',
  sad: 'sad',
  angry: 'angry',
  surprised: 'surprised',
  thinking: 'thinking',
  concerned: 'concerned',
  satisfied: 'happy',
  neutral: 'neutral'
};

function getSvgFace(emotion) {
  const state = EMOTION_TO_STATE[emotion] || 'neutral';

  let eyes = '';
  let mouth = '';

  switch (state) {
    case 'neutral':
      eyes = `<circle cx="30" cy="32" r="4" fill="var(--text-secondary)"/>
              <circle cx="50" cy="32" r="4" fill="var(--text-secondary)"/>`;
      mouth = `<path d="M 30 50 Q 40 50 50 50" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
    case 'thinking':
      eyes = `<line x1="26" y1="32" x2="34" y2="32" stroke="var(--text-secondary)" stroke-width="3" stroke-linecap="round"/>
              <line x1="46" y1="32" x2="54" y2="32" stroke="var(--text-secondary)" stroke-width="3" stroke-linecap="round"/>`;
      mouth = `<path d="M 30 52 Q 35 48 40 52 Q 45 56 50 52" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
    case 'happy':
      eyes = `<path d="M 26 34 Q 30 28 34 34" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>
              <path d="M 46 34 Q 50 28 54 34" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>`;
      mouth = `<path d="M 28 48 Q 40 60 52 48" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
    case 'concerned':
      eyes = `<path d="M 26 30 Q 30 34 34 30" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>
              <path d="M 46 30 Q 50 34 54 30" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>`;
      mouth = `<path d="M 30 56 Q 40 48 50 56" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
    case 'sad':
      // 下がった目 + への字口
      eyes = `<path d="M 26 30 Q 30 34 34 30" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>
              <path d="M 46 30 Q 50 34 54 30" stroke="var(--text-secondary)" stroke-width="3" fill="none" stroke-linecap="round"/>`;
      mouth = `<path d="M 30 55 Q 40 50 50 55" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
    case 'angry':
      // つり上がった目 + きつい口
      eyes = `<line x1="26" y1="34" x2="34" y2="30" stroke="var(--text-secondary)" stroke-width="3" stroke-linecap="round"/>
              <line x1="46" y1="30" x2="54" y2="34" stroke="var(--text-secondary)" stroke-width="3" stroke-linecap="round"/>`;
      mouth = `<path d="M 30 54 Q 40 50 50 54" stroke="var(--text-secondary)" stroke-width="2.5" fill="none" class="mouth"/>`;
      break;
    case 'surprised':
      // ○○目 + O口
      eyes = `<circle cx="30" cy="32" r="5" stroke="var(--text-secondary)" stroke-width="2.5" fill="none"/>
              <circle cx="50" cy="32" r="5" stroke="var(--text-secondary)" stroke-width="2.5" fill="none"/>`;
      mouth = `<circle cx="40" cy="53" r="4" stroke="var(--text-secondary)" stroke-width="2" fill="none" class="mouth"/>`;
      break;
  }

  return `<svg viewBox="0 0 80 80" width="80" height="80" xmlns="http://www.w3.org/2000/svg">
    ${eyes}
    ${mouth}
  </svg>`;
}

export function renderAvatar(emotion) {
  const state = EMOTION_TO_STATE[emotion] || 'neutral';
  return `<div class="openclaw-avatar avatar-${state}">
    ${getSvgFace(emotion)}
  </div>`;
}

export function getEmotionLabel(emotion) {
  return EMOTION_LABELS[emotion] || EMOTION_LABELS.neutral;
}
