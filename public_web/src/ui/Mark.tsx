/** The site's mark, beside its name. */
export function Mark() {
  return (
    <svg className="site-mark" width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
      <rect x="1" y="1" width="30" height="30" rx="8" fill="#176273" />
      <path
        d="M11 23V9h6.2a4.4 4.4 0 0 1 0 8.8H11"
        fill="none"
        stroke="#FFFFFF"
        strokeWidth="2.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
