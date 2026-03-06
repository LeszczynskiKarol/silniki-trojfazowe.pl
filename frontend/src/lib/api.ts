const BACKEND = "https://api.silniki-elektryczne.com.pl";
export const LAMBDA = "https://vos9dl4ovl.execute-api.eu-north-1.amazonaws.com";
export const MAIN_SHOP = "https://www.silniki-elektryczne.com.pl";

/**
 * silniki-trojfazowe.pl — tylko kategoria "trojfazowe", dowolny stan (nowy/używany/nieużywany)
 */
function isTrojfazowy(p: any): boolean {
  const cats = p.categories || [];
  if (!cats.length) return false;
  return cats.some((c: any) => {
    const s = c.category?.slug || c.slug || "";
    return s === "trojfazowe";
  });
}

function isEligible(p: any): boolean {
  if (!p.marketplaces?.ownStore?.active) return false;
  if (!p.marketplaces?.ownStore?.slug) return false;
  if (p.stock < 1) return false;
  return isTrojfazowy(p);
}

function normalizePower(p: any): any {
  if (p.power?.value != null) {
    const s = String(p.power.value)
      .replace(/kW/gi, "")
      .replace(",", ".")
      .trim();
    const n = parseFloat(s);
    if (!isNaN(n) && n > 0) p.power.value = n;
    else p.power.value = null;
  }
  return p;
}

let _cached: any[] | null = null;

export async function fetchAllProducts(): Promise<any[]> {
  if (_cached) return _cached;
  const res = await fetch(`${BACKEND}/api/products?limit=2000&page=1`);
  const data = await res.json();
  const all = data.data?.products || data.data || [];
  _cached = all.filter(isEligible).map(normalizePower);
  return _cached!;
}

export async function getMotor(slug: string) {
  const res = await fetch(`${BACKEND}/api/shop/product/${slug}`);
  if (!res.ok) return null;
  const data = await res.json();
  if (!data.success) return null;
  const p = data.data.product;
  if (!p.marketplaces?.ownStore?.active) return null;
  if (!p.marketplaces?.ownStore?.slug) return null;
  if (p.stock < 1) return null;
  if (!isTrojfazowy(p)) return null;
  return data;
}

export async function getAllProductSlugs(): Promise<string[]> {
  const all = await fetchAllProducts();
  return all.map((p: any) => p.marketplaces.ownStore.slug).filter(Boolean);
}

export function formatPrice(price: number | string): string {
  return new Intl.NumberFormat("pl-PL", {
    style: "currency",
    currency: "PLN",
    minimumFractionDigits: 0,
  }).format(Number(price));
}

export function getImageUrl(product: any): string {
  return product.mainImage || product.images?.[0] || "/placeholder.webp";
}

// Alias dla kompatybilności z istniejącymi stronami
export const fetchAllMotorsRaw = fetchAllProducts;
