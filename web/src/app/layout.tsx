import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  title: "AskGPT notes",
  description: "Your highlights, notes and AI explanations, synced from KOReader.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <header className="site-header">
          <Link href="/" className="wordmark">
            AskGPT notes
          </Link>
          <nav>
            <Link href="/pair">Pair a device</Link>
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
