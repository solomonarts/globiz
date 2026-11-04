import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = { title: "GlowBiz — Skills that build a future", description: "Inclusive vocational learning, certification and opportunity." };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="en"><body>{children}</body></html>; }
