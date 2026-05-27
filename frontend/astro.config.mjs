import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import tailwind from "@astrojs/tailwind";
import sitemap from "@astrojs/sitemap";

const NOINDEX_PATHS = [
  "/checkout",
  "/zamowienie",
  "/kontakt",
  "/polityka-prywatnosci",
  "/regulamin",
  "/odstapienie-od-umowy",
  "/przetwarzanie-danych",
  "/koszty-wysylki",
  "/formy-platnosci",
  "/404",
];

const BUILD_LASTMOD = new Date().toISOString();

export default defineConfig({
  output: "static",
  integrations: [
    react(),
    tailwind(),
    sitemap({
      filter: (page) => {
        const u = page.replace(/\/$/, "");
        return !NOINDEX_PATHS.some((p) => u.endsWith(p));
      },
      serialize(item) {
        return { ...item, lastmod: BUILD_LASTMOD };
      },
    }),
  ],
  site: "https://www.silniki-trojfazowe.pl",
});
