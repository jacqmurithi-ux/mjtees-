import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

type ErrorBoundaryState = { error: Error | null };

class StartupErrorBoundary extends React.Component<React.PropsWithChildren, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    console.error("MJ Tees application startup/render error:", error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      const message = this.state.error.message || "An unexpected application error occurred.";
      return (
        <main style={{ minHeight: "100vh", boxSizing: "border-box", padding: "32px 20px", display: "grid", placeItems: "center", background: "#f4f6f7", color: "#17242c", fontFamily: "Arial, sans-serif" }}>
          <section style={{ width: "min(100%, 560px)", boxSizing: "border-box", padding: "28px", background: "#fff", border: "1px solid #e3e7e9", borderRadius: "14px" }}>
            <div style={{ fontWeight: 800, color: "#f28c28", letterSpacing: "0.08em" }}>MJ PRINTING &amp; BRANDING</div>
            <h1 style={{ margin: "18px 0 8px", fontSize: "25px" }}>The page could not start</h1>
            <p style={{ lineHeight: 1.6, color: "#52616a" }}>The website loaded, but an application error stopped it from displaying. Please share the diagnostic message below with support.</p>
            <pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", padding: "14px", background: "#f5f7f8", borderRadius: "8px", color: "#8b3027", fontSize: "13px" }}>{message}</pre>
            <button onClick={() => window.location.reload()} style={{ border: 0, borderRadius: "8px", padding: "12px 16px", background: "#f28c28", color: "#17242c", fontWeight: 700 }}>Reload page</button>
          </section>
        </main>
      );
    }
    return this.props.children;
  }
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  document.body.textContent = "MJ Tees could not start: the root page element is missing.";
} else {
  ReactDOM.createRoot(rootElement).render(
    <React.StrictMode><StartupErrorBoundary><App /></StartupErrorBoundary></React.StrictMode>,
  );
}
