import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

export const editorTheme = EditorView.theme(
  {
    "&": {
      backgroundColor: "transparent",
      color: "#eeffff",
    },
    ".cm-content": {
      caretColor: "#00d9ff",
      padding: "0.5rem 0",
    },
    ".cm-cursor, .cm-dropCursor": {
      borderLeftColor: "#00d9ff",
    },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
      backgroundColor: "rgba(0, 217, 255, 0.15)",
    },
    ".cm-activeLine": {
      backgroundColor: "rgba(255, 255, 255, 0.03)",
    },
    "&.cm-focused .cm-matchingBracket": {
      backgroundColor: "rgba(255, 255, 255, 0.12)",
      outline: "1px solid rgba(255, 255, 255, 0.2)",
    },
    /* Line number gutter styling */
    ".cm-gutters": {
      backgroundColor: "transparent",
      color: "rgba(255, 255, 255, 0.18)",
      borderRight: "1px solid rgba(255, 255, 255, 0.06)",
      fontVariantNumeric: "tabular-nums",
    },
    ".cm-gutter": {
      backgroundColor: "transparent",
    },
    ".cm-gutterElement": {
      backgroundColor: "transparent",
      color: "rgba(255, 255, 255, 0.18)",
      paddingLeft: "0.75rem",
      paddingRight: "1rem",
    },
    ".cm-activeLineGutter": {
      backgroundColor: "transparent",
      color: "rgba(255, 255, 255, 0.45)",
    },
    ".cm-tooltip": {
      backgroundColor: "#252526",
      color: "#cccccc",
      border: "1px solid #454545",
      borderRadius: "3px",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.36)",
      fontSize: "13px",
      lineHeight: "1.45",
      maxWidth: "min(500px, calc(100vw - 32px))",
      zIndex: "2000",
    },
    ".cm-tooltip.cm-tooltip-autocomplete": {
      backgroundColor: "#252526",
      border: "1px solid #454545",
      maxWidth: "none",
    },
    ".cm-tooltip-autocomplete ul li[aria-selected]": {
      backgroundColor: "rgba(74, 222, 128, 0.16)",
      color: "#eeffff",
    },
    ".cm-tooltip.cm-tooltip-hover": {
      maxWidth: "min(500px, calc(100vw - 32px))",
      maxHeight: "min(280px, 45vh)",
      overflow: "auto",
    },
    ".cm-lsp-hover-tooltip.cm-lsp-documentation": {
      padding: "6px 10px",
      maxWidth: "100%",
      boxSizing: "border-box",
      whiteSpace: "normal",
      wordBreak: "break-word",
      color: "#cccccc",
    },
    ".cm-lsp-documentation": {
      color: "#cccccc",
    },
    ".cm-lsp-documentation p": {
      margin: "0.45em 0",
    },
    ".cm-lsp-documentation p:first-child": {
      marginTop: "0",
    },
    ".cm-lsp-documentation p:last-child": {
      marginBottom: "0",
    },
    ".cm-lsp-documentation pre": {
      margin: "0",
      padding: "0",
      backgroundColor: "transparent",
      border: "none",
      borderRadius: "0",
      overflowX: "auto",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word",
      fontFamily: "'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', monospace",
      fontSize: "12px",
      lineHeight: "1.4",
      color: "#d4d4d4",
    },
    ".cm-lsp-documentation pre code": {
      background: "transparent",
      border: "none",
      padding: "0",
      margin: "0",
      display: "inline",
      whiteSpace: "inherit",
      color: "inherit",
      fontSize: "inherit",
      borderRadius: "0",
    },
    ".cm-lsp-documentation code": {
      backgroundColor: "transparent",
      color: "#ce9178",
      padding: "0",
      borderRadius: "0",
      border: "none",
      fontFamily: "'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', monospace",
      fontSize: "0.92em",
      whiteSpace: "pre-wrap",
      display: "inline",
      margin: "0",
    },
    ".cm-lsp-documentation a": {
      color: "#4ade80",
      textDecoration: "none",
    },
    ".cm-lsp-documentation a:hover": {
      textDecoration: "underline",
    },
    ".cm-lsp-documentation ul": {
      margin: "0.4em 0 0.4em 1.1em",
      padding: "0",
    },
    ".cm-lsp-documentation li": {
      margin: "0.15em 0",
    },
    /* Scrollbar styling */
    ".cm-scroller": {
      scrollbarWidth: "thin" as any,
      scrollbarColor: "rgba(255, 255, 255, 0.14) transparent",
    },
  },
  { dark: true }
);

/* Syntax highlighting matching playground.css / home.css color palette */
export const editorHighlightStyle = syntaxHighlighting(
  HighlightStyle.define([
    { tag: t.comment, color: "#7a9aa8", fontStyle: "italic" },
    { tag: t.lineComment, color: "#7a9aa8", fontStyle: "italic" },
    { tag: t.blockComment, color: "#7a9aa8", fontStyle: "italic" },

    { tag: t.keyword, color: "#c792ea" },
    { tag: t.controlKeyword, color: "#c792ea" },
    { tag: t.operatorKeyword, color: "#89ddff" },
    { tag: t.definitionKeyword, color: "#c792ea" },
    { tag: t.moduleKeyword, color: "#c792ea" },

    { tag: t.operator, color: "#89ddff" },
    { tag: t.punctuation, color: "#89ddff" },
    { tag: t.bracket, color: "#89ddff" },
    { tag: t.separator, color: "#89ddff" },

    { tag: t.string, color: "#c3e88d" },
    { tag: t.special(t.string), color: "#c3e88d" },
    { tag: t.escape, color: "#eeffff" },

    { tag: t.number, color: "#f78c6c" },
    { tag: t.integer, color: "#f78c6c" },
    { tag: t.float, color: "#f78c6c" },
    { tag: t.bool, color: "#f78c6c" },

    { tag: t.function(t.variableName), color: "#82aaff" },
    { tag: t.function(t.definition(t.variableName)), color: "#82aaff" },

    { tag: t.typeName, color: "#ffcb6b" },
    { tag: t.className, color: "#ffcb6b" },
    { tag: t.definition(t.typeName), color: "#ffcb6b" },

    { tag: t.variableName, color: "#eeffff" },
    { tag: t.definition(t.variableName), color: "#eeffff" },
    { tag: t.special(t.variableName), color: "#82aaff" },
    { tag: t.propertyName, color: "#f78c6c" },

    { tag: t.attributeName, color: "#f78c6c" },
    { tag: t.labelName, color: "#c792ea" },

    { tag: t.tagName, color: "#f07178" },
    { tag: t.meta, color: "#89ddff" },
  ])
);
