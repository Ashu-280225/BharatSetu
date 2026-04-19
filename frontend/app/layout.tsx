import dynamic from "next/dynamic";
import "./globals.css";

const Providers = dynamic(
  () => import("./providers").then((m) => m.Providers),
  { ssr: false }
);

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <nav className="navbar">
            <span className="brand">
              <span className="brand-dot" />
              BharatSetu
            </span>
            <div className="nav-links">
              <a href="/dashboard" className="nav-link">Dashboard</a>
              <a href="/bridge" className="nav-link">Bridge</a>
              <a href="/history" className="nav-link">History</a>
            </div>
          </nav>
          <main>{children}</main>
        </Providers>
      </body>
    </html>
  );
}
