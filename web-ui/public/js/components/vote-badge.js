const VOTE_LABELS = {
  approve: '\u8CDB\u6210',
  approve_with_modification: '\u4FEE\u6B63\u4ED8\u8CDB\u6210',
  reject: '\u53CD\u5BFE'
};

export function voteBadge(vote) {
  const label = VOTE_LABELS[vote] || vote;
  return `<span class="badge badge-vote badge-${vote}">${label}</span>`;
}
