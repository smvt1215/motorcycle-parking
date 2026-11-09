const ROAD = '#1F6172';
const INK = '#154B58';
const LANE = '#F2C200';
const WHITE = '#FFFFFF';

/** The parking marks: where each sits as a share of the map, and its colour. */
const MARKS = [
  { x: 0.22, y: 0.26, fill: WHITE },
  { x: 0.71, y: 0.2, fill: WHITE },
  { x: 0.84, y: 0.62, fill: LANE },
  { x: 0.13, y: 0.68, fill: LANE },
  { x: 0.93, y: 0.88, fill: WHITE },
];

/**
 * The drawn street map (no photographs: canvas note t4). Drawn at the board's
 * size and cropped to its box, never squashed; the phone and the wider boards
 * each have their own drawing, so the marks stay inside the crop.
 */
export function Street({ width, height, className }: { width: number; height: number; className: string }) {
  const across = [40, 40 + height / 3, 40 + (2 * height) / 3, 40 + height];
  const main = across[1]!;
  const along = (y: number) => `M-50 ${Math.round(y)}L${width + 50} ${Math.round(y) - 100}`;
  return (
    <svg
      className={className}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="xMidYMid slice"
      aria-hidden="true"
    >
      <rect width={width} height={height} fill={INK} />
      {[0, 1, 2, 3, 4, 5].map((road) => {
        const x = Math.round(-50 + (road * width) / 4);
        return (
          <path
            key={road}
            d={`M${x} ${height + 50}L${x + 150} -50`}
            stroke={ROAD}
            strokeWidth={road % 2 ? 26 : 16}
          />
        );
      })}
      {across.map((y) => (
        <path key={y} d={along(y)} stroke={ROAD} strokeWidth={y === main ? 30 : 16} />
      ))}
      <path d={along(main)} stroke={LANE} strokeWidth="3" strokeDasharray="20 16" />
      {MARKS.map(({ x, y, fill }) => {
        const cx = Math.round(x * width);
        const cy = Math.round(y * height);
        return (
          <g key={x}>
            <circle cx={cx} cy={cy} r="17" fill={fill} />
            <text
              x={cx}
              y={cy + 6}
              textAnchor="middle"
              fontFamily="Outfit, sans-serif"
              fontWeight="800"
              fontSize="17"
              fill={INK}
            >
              P
            </text>
          </g>
        );
      })}
    </svg>
  );
}
