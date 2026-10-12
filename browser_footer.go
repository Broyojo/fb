//go:build !fbmac

package main

// pageFooter links the health and version probes from the bottom of every
// rendered page except markdown documents, which stay clean. Inline styles
// keep it self-contained, so templates and pandoc output can append it
// without touching their own CSS.
const pageFooter = `<footer style="margin-top:3rem;padding-top:0.5rem;border-top:1px solid #eaeef0;font-size:0.75rem;color:#8c959f"><a style="color:#8c959f" href="/` + assetPrefix + `/healthz">healthz</a> &middot; <a style="color:#8c959f" href="/` + assetPrefix + `/version">version</a></footer>
`
