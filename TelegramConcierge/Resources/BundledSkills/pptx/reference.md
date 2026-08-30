# PPTX Reference

Supporting detail for the pptx skill. Read the section you need.

## Modes

| Mode | Use when | Default behavior |
| --- | --- | --- |
| Create | New deck from prompt/source | Build story, design system, native slides, render QA |
| Targeted edit | User wants specific changes | Preserve deck style and make surgical edits |
| Template-follow | User supplied template/source | Reuse layouts, placeholders, typography, page furniture |
| Content-to-deck | User supplied notes/docs | Extract structure, turn into slide sequence, avoid inventing facts |

## Planning The Deck

Before building slides, decide:

- Audience and decision/use case.
- Slide count or expected length.
- Source facts and what must not be invented.
- Visual grammar from any template/reference.
- Slide size, margins, typography, palette, footer/source treatment.
- What each slide should communicate: claim, explanation, walkthrough, reference, appendix, divider, or visual.
- Risk areas: crowded text, tiny labels, bad image quality, charts without sources, placeholder misuse, template drift.

## Authoring Pattern

```python
from pptx import Presentation
from pptx.util import Inches, Pt

prs = Presentation()                      # or Presentation("template.pptx")
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
slide = prs.slides.add_slide(prs.slide_layouts[6])
box = slide.shapes.add_textbox(Inches(0.6), Inches(0.5), Inches(8.8), Inches(0.8))
box.text_frame.text = "Growth slowed, but retention improved."
prs.save("deck.pptx")
```

When following a template, enumerate its layouts/placeholders first (use `inspect_pptx.py --layouts`) and add slides from those layouts rather than blank ones. Copy/edit existing slide types when that is safer than recreating them.

## Slide Craft Defaults

Defaults, not laws:

- Prefer one main idea per slide.
- Use native editable objects when practical.
- Use screenshots/images only when they are real, provided, verified, or clearly illustrative.
- Use charts, tables, diagrams, timelines, screenshots, quotes, or comparisons as evidence when the slide makes an argument.
- Keep labels and source notes readable.
- Avoid overcrowding. Split a slide or move detail to appendix when needed.
- Preserve template conventions for logos, footers, typography, and spacing.

## Geometry And Objects

- Text boxes need enough internal margin and height; avoid text overflow.
- Equal-role boxes/nodes should use consistent dimensions, padding, and hierarchy.
- Connectors should visibly attach to intended objects and avoid ambiguous crossings.
- Tables need deliberate column widths and readable padding.
- Charts need honest scales, units, source notes, and legible labels.
- Images should preserve aspect ratio. Crop deliberately instead of stretching.
- Footers/source lines/page numbers should be quiet and consistent.

## Template And Existing Decks

- Inspect layouts and placeholders before writing.
- Reuse existing layouts where possible.
- Preserve theme fonts, colors, logo placement, page numbers, and footer conventions unless the user asks for restyling.
- Do not restyle unrelated slides during targeted edits.
- Keep a short note of meaningful deviations from the template.

## Visual QA Checklist

- Expected slide count and no accidental blank slides.
- Text is not clipped, overlapping, or too small.
- Images/logos render sharply and are not stretched.
- Charts, tables, and diagrams are readable.
- Footer/source/page markers are consistent.
- Template-following decks preserve the source grammar.
- Thumbnail/contact-sheet view makes the sequence understandable.
- Any slide making an argument has evidence or a concrete visual, not just decoration.

## Common Failures

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Text cut off | Text frame overflow | Shorten copy, split slide, enlarge box, or reduce type within readability |
| Deck feels generic | Repeated default card layout | Choose slide forms based on content and evidence |
| Slide says nothing | Topic title plus filler bullets | Rewrite around a point, proof, or concrete walkthrough |
| Chart unreadable | Too small or too many labels | Make it dominant, simplify labels, move detail to appendix |
| Connectors float | Lines not aligned to nodes | Recompute geometry and inspect render |
| Image distorted | Forced width/height | Preserve aspect ratio and crop deliberately |
| Template breaks | Wrong layout/placeholder assumptions | Inspect and reuse placeholders/layouts |
| Fonts change elsewhere | Unavailable fonts | Use template fonts or common system fonts |
| Render differs from object model | PowerPoint/LibreOffice layout behavior | Trust rendered output and adjust |
