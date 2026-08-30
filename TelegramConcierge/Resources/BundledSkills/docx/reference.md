# DOCX Reference

Supporting detail for the docx skill. Read the section you need.

## Task Modes

| Mode | Use when | Default behavior |
| --- | --- | --- |
| Create | New document from prompt/source | Choose an archetype, build structure, render QA |
| Targeted edit | User wants limited changes | Preserve layout and make surgical edits |
| Major rewrite | User wants stronger structure or tone | Preserve facts, redesign organization carefully |
| Template-follow | User supplied a branded/source DOCX | Start from it and preserve style/furniture |
| Redline/comment | User wants review feedback | Put comments/markers near relevant text |
| Google Docs-ready | Output will be imported to Google Docs | Prefer simple native styles and avoid Word-only tricks |

## Planning The Document

Before generating or editing, decide:

- Document type: memo, report, proposal, SOP, contract, form, letter, CV, handbook, questionnaire, brief, appendix pack.
- Audience and editing destination: Word, Google Docs, internal review, client-ready, legal review.
- Page setup: A4/Letter, portrait/landscape, margins, headers/footers.
- Content forms: prose, bullets, numbered steps, checklist, table, form field, figure, appendix, comment.
- Risk areas: long tables, nested lists, page breaks, comments, headers/footers, images, template preservation.

Choose the simplest structure that lets collaborators edit comfortably.

## Authoring Pattern

```python
from docx import Document
from docx.shared import Inches, Pt

doc = Document()                      # or Document("template.docx")
section = doc.sections[0]
section.top_margin = Inches(1)
section.bottom_margin = Inches(1)
section.left_margin = Inches(1)
section.right_margin = Inches(1)

style = doc.styles["Normal"]
style.font.name = "Aptos"
style.font.size = Pt(11)

doc.add_heading("Decision Memo", level=1)
doc.add_paragraph("Recommendation: proceed with the focused pilot.")
doc.save("output.docx")
```

When following a template, open it with `Document("template.docx")` and reuse its styles instead of rebuilding the look from scratch.

## Tables And Forms

Tables are a common source of broken DOCX output. Treat them as structure:

- Give columns deliberate widths. Short fields like date, owner, amount, status, score, or checkbox should be compact; narrative fields get space.
- Let rows expand. Avoid fixed row heights that clip wrapped text.
- Use enough padding and line spacing that text is not pinned to borders.
- Repeat header rows on long tables when possible.
- Align by data type: right-align numbers/currency, center compact statuses/dates/checkmarks, left-align narrative text.
- Keep captions/source notes close to the table.
- Forms should feel fillable: clear labels, visible response areas, generous row height, and restrained borders.

## Visual QA Checklist

- Opens without repair prompts.
- Expected page count and no accidental blank pages.
- Title, headings, body, captions, callouts, and footnotes have clear hierarchy.
- No clipped text, overlapping objects, broken images, or missing glyphs.
- Tables fit the page, rows expand, and columns are deliberate.
- Lists wrap with correct indentation.
- Headers, footers, page numbers, dates, confidentiality labels, and source notes are aligned.
- Existing-document edits did not accidentally restyle unrelated content.
- Google Docs-ready files avoid complex floating objects and Word-only decoration.

## Common Failures

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Navigation pane is empty | Fake heading formatting | Apply real Heading styles |
| Bullets wrap badly | Manual bullets or bad indents | Use real list/numbering styles |
| Table text clips | Fixed row height or tight padding | Allow row growth and add padding |
| Table runs off page | Default widths/autofit | Set explicit widths and compact short columns |
| Footer overlaps body | Bad section margins/footer distance | Adjust section properties and re-render |
| Image/logo distorted | Forced width and height | Preserve aspect ratio or crop deliberately |
| Template branding lost | Rebuilt from scratch | Start from template and reuse styles |
| Google Docs import looks odd | Word-only layout tricks | Simplify to native styles/tables |
| Render differs from XML inspection | Word layout engine behavior | Trust visual render and fix the DOCX |
