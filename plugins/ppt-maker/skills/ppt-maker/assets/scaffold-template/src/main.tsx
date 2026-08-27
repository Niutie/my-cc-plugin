import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
// Order matters: base.css holds DEFAULTS, tokens.css holds the theme.
// The theme must be able to override a default, so it is imported last.
// (Getting this backwards silently fed the browser the fallback chart
// palette while the exporter read the theme's own — two renderers, two
// sets of colours, and nothing but a screenshot to reveal it.)
import "./styles/fonts.css";
import "./styles/base.css";
import "./styles/tokens.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
