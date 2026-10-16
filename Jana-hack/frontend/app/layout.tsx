import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "JanaМен — Digital HR",
  description: "Работа, развитие и забота о команде в одном пространстве.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="ru"><body>{children}</body></html>;
}
