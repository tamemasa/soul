const VOTE_LABELS = {
  approve: 'Approve',
  approve_with_modification: 'Modify',
  reject: 'Reject'
};

export function voteBadge(vote) {
  const label = VOTE_LABELS[vote] || vote;
  return `<span class="badge badge-vote badge-${vote}">${label}</span>`;
}
