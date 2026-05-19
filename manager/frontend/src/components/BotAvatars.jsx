// 15 Built-in-Avatare im einheitlichen Stil:
//   - viewBox 0 0 64 64, dunkler abgerundeter Hintergrund
//   - Strichstaerke 3, runde Linienenden, Akzentfarbe #00c896
//   - Augen / Punkte als gefuellte Kreise, gleiche Farbe
//
// Aufbau pro Eintrag: { id, name, svg }. svg ist ein XML-String, damit er
// sowohl im Picker via dangerouslySetInnerHTML gerendert als auch fuer den
// Upload per Canvas zu PNG rasterisiert werden kann.

const BG = `<rect width="64" height="64" rx="14" fill="#0f2620"/>`;
const S = 'fill="none" stroke="#00c896" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"';
const DOT = 'fill="#00c896"';

function svg(body) {
  // Doppelte Groessenangabe: Attribute width/height geben dem <img>-Loader
  // eine definierte intrinsic size (64x64) fuers Rasterisieren, das style-
  // Attribut laesst das Bild im Container CSS-gesteuert wachsen/schrumpfen.
  return `<svg viewBox="0 0 64 64" width="64" height="64" xmlns="http://www.w3.org/2000/svg" style="width:100%;height:100%;display:block">${BG}${body}</svg>`;
}

export const BOT_AVATARS = [
  {
    id: "robot",
    name: "Roboter",
    svg: svg(`
      <line x1="32" y1="10" x2="32" y2="18" ${S}/>
      <circle cx="32" cy="9" r="2" ${DOT}/>
      <rect x="16" y="18" width="32" height="28" rx="5" ${S}/>
      <circle cx="24" cy="30" r="2.5" ${DOT}/>
      <circle cx="40" cy="30" r="2.5" ${DOT}/>
      <line x1="24" y1="40" x2="40" y2="40" ${S}/>
      <line x1="20" y1="46" x2="20" y2="52" ${S}/>
      <line x1="44" y1="46" x2="44" y2="52" ${S}/>
    `),
  },
  {
    id: "cyclops",
    name: "Zyklop",
    svg: svg(`
      <circle cx="32" cy="32" r="20" ${S}/>
      <circle cx="32" cy="30" r="7" ${S}/>
      <circle cx="32" cy="30" r="3" ${DOT}/>
      <line x1="20" y1="44" x2="28" y2="44" ${S}/>
      <line x1="36" y1="44" x2="44" y2="44" ${S}/>
    `),
  },
  {
    id: "owl",
    name: "Eule",
    svg: svg(`
      <path d="M 14 30 Q 14 14 32 14 Q 50 14 50 30 L 50 42 Q 50 54 32 54 Q 14 54 14 42 Z" ${S}/>
      <circle cx="24" cy="28" r="6" ${S}/>
      <circle cx="40" cy="28" r="6" ${S}/>
      <circle cx="24" cy="28" r="2" ${DOT}/>
      <circle cx="40" cy="28" r="2" ${DOT}/>
      <path d="M 30 36 L 32 40 L 34 36 Z" ${DOT}/>
    `),
  },
  {
    id: "cat",
    name: "Katze",
    svg: svg(`
      <polyline points="14,28 18,12 26,22" ${S}/>
      <polyline points="50,28 46,12 38,22" ${S}/>
      <circle cx="32" cy="34" r="18" ${S}/>
      <circle cx="25" cy="32" r="2" ${DOT}/>
      <circle cx="39" cy="32" r="2" ${DOT}/>
      <path d="M 28 40 Q 32 44 36 40" ${S}/>
      <line x1="18" y1="36" x2="22" y2="37" ${S}/>
      <line x1="42" y1="37" x2="46" y2="36" ${S}/>
    `),
  },
  {
    id: "fox",
    name: "Fuchs",
    svg: svg(`
      <polyline points="16,30 18,14 28,22" ${S}/>
      <polyline points="48,30 46,14 36,22" ${S}/>
      <path d="M 18 26 Q 18 44 32 52 Q 46 44 46 26" ${S}/>
      <circle cx="26" cy="32" r="2" ${DOT}/>
      <circle cx="38" cy="32" r="2" ${DOT}/>
      <circle cx="32" cy="42" r="1.6" ${DOT}/>
    `),
  },
  {
    id: "ghost",
    name: "Geist",
    svg: svg(`
      <path d="M 14 30 Q 14 14 32 14 Q 50 14 50 30 L 50 52 L 44 48 L 38 52 L 32 48 L 26 52 L 20 48 L 14 52 Z" ${S}/>
      <circle cx="25" cy="30" r="2.5" ${DOT}/>
      <circle cx="39" cy="30" r="2.5" ${DOT}/>
      <path d="M 28 38 Q 32 42 36 38" ${S}/>
    `),
  },
  {
    id: "alien",
    name: "Alien",
    svg: svg(`
      <ellipse cx="32" cy="32" rx="16" ry="20" ${S}/>
      <ellipse cx="24" cy="30" rx="3" ry="5" ${DOT}/>
      <ellipse cx="40" cy="30" rx="3" ry="5" ${DOT}/>
      <line x1="26" y1="44" x2="38" y2="44" ${S}/>
      <line x1="22" y1="14" x2="20" y2="10" ${S}/>
      <line x1="42" y1="14" x2="44" y2="10" ${S}/>
    `),
  },
  {
    id: "lightning",
    name: "Blitz",
    svg: svg(`
      <path d="M 34 10 L 20 36 L 30 36 L 26 54 L 44 26 L 34 26 Z" ${S}/>
    `),
  },
  {
    id: "star",
    name: "Stern",
    svg: svg(`
      <polygon points="32,12 38,26 53,28 42,38 45,53 32,45 19,53 22,38 11,28 26,26" ${S}/>
    `),
  },
  {
    id: "heart",
    name: "Herz",
    svg: svg(`
      <path d="M 32 52 L 14 32 Q 8 22 18 16 Q 26 14 32 24 Q 38 14 46 16 Q 56 22 50 32 Z" ${S}/>
    `),
  },
  {
    id: "crown",
    name: "Krone",
    svg: svg(`
      <path d="M 10 24 L 18 40 L 26 22 L 32 38 L 38 22 L 46 40 L 54 24 L 54 48 L 10 48 Z" ${S}/>
      <line x1="14" y1="48" x2="50" y2="48" ${S}/>
      <circle cx="10" cy="24" r="2" ${DOT}/>
      <circle cx="54" cy="24" r="2" ${DOT}/>
      <circle cx="32" cy="38" r="2" ${DOT}/>
    `),
  },
  {
    id: "bell",
    name: "Glocke",
    svg: svg(`
      <path d="M 18 44 Q 18 22 32 22 Q 46 22 46 44 Z" ${S}/>
      <line x1="14" y1="44" x2="50" y2="44" ${S}/>
      <circle cx="32" cy="52" r="3" ${S}/>
      <line x1="32" y1="18" x2="32" y2="22" ${S}/>
      <circle cx="32" cy="16" r="2" ${DOT}/>
    `),
  },
  {
    id: "megaphone",
    name: "Megafon",
    svg: svg(`
      <path d="M 14 28 L 14 40 L 24 40 L 48 50 L 48 18 L 24 28 Z" ${S}/>
      <line x1="24" y1="28" x2="24" y2="40" ${S}/>
      <path d="M 52 24 Q 58 28 58 34 Q 58 40 52 44" ${S}/>
    `),
  },
  {
    id: "gear",
    name: "Zahnrad",
    svg: svg(`
      <circle cx="32" cy="32" r="10" ${S}/>
      <circle cx="32" cy="32" r="3" ${DOT}/>
      <line x1="32" y1="10" x2="32" y2="18" ${S}/>
      <line x1="32" y1="46" x2="32" y2="54" ${S}/>
      <line x1="10" y1="32" x2="18" y2="32" ${S}/>
      <line x1="46" y1="32" x2="54" y2="32" ${S}/>
      <line x1="16" y1="16" x2="22" y2="22" ${S}/>
      <line x1="42" y1="42" x2="48" y2="48" ${S}/>
      <line x1="16" y1="48" x2="22" y2="42" ${S}/>
      <line x1="42" y1="22" x2="48" y2="16" ${S}/>
    `),
  },
  {
    id: "chat",
    name: "Chat",
    svg: svg(`
      <path d="M 12 16 L 52 16 Q 56 16 56 20 L 56 40 Q 56 44 52 44 L 28 44 L 18 52 L 18 44 L 12 44 Q 8 44 8 40 L 8 20 Q 8 16 12 16 Z" ${S}/>
      <circle cx="22" cy="30" r="2.5" ${DOT}/>
      <circle cx="32" cy="30" r="2.5" ${DOT}/>
      <circle cx="42" cy="30" r="2.5" ${DOT}/>
    `),
  },
];

/**
 * Rasterisiert eine der Built-in-SVGs zu einem PNG-Blob (256x256), damit das
 * Bild verlustfrei aussehbar in Synapse landet und das /thumbnail-Endpoint
 * von Synapse damit umgehen kann (SVG-Thumbnails sind je nach Version
 * heikel; PNG geht immer).
 */
export function avatarToPngBlob(svgString, size = 256) {
  return new Promise((resolve, reject) => {
    const svgBlob = new Blob([svgString], { type: "image/svg+xml;charset=utf-8" });
    const url = URL.createObjectURL(svgBlob);
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement("canvas");
      canvas.width = size;
      canvas.height = size;
      const ctx = canvas.getContext("2d");
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(img, 0, 0, size, size);
      URL.revokeObjectURL(url);
      canvas.toBlob(
        b => b ? resolve(b) : reject(new Error("canvas.toBlob failed")),
        "image/png",
      );
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("SVG konnte nicht geladen werden"));
    };
    img.src = url;
  });
}
