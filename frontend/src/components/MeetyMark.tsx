// The Meety mark: a three-bar voice level in an ink square (same drawing as src-tauri/icons/meety.svg).
export function MeetyMark({ size = 24, className }: { size?: number; className?: string }) {
  return (
    <svg viewBox="100 100 824 824" width={size} height={size} aria-hidden="true" className={className}>
      <rect x="100" y="100" width="824" height="824" rx="185" fill="#141414" />
      <rect x="284" y="362" width="104" height="300" rx="52" fill="#ffffff" />
      <rect x="460" y="252" width="104" height="520" rx="52" fill="#5b93e8" />
      <rect x="636" y="322" width="104" height="380" rx="52" fill="#ffffff" />
    </svg>
  );
}
