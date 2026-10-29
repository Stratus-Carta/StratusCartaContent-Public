"""
Builds the NovaFiber Word templates for Salesforce Document Generation (server-side, JSON token data).

  docs/templates/NovaFiber_Residential_Service_Agreement.docx   households, signed at checkout
  docs/templates/NovaFiber_Business_Proposal.docx               multi-site business quotes

Both are native Salesforce document templates (scripts/docgen/upload_templates.apex registers them):
  Residential  Salesforce Contracts template (Contract_Lifecycle_Management), tokens from the Data Mappers
               NF_HomeAgreementExtract → NF_HomeAgreementTransform (Contract → account, signer, source quote lines).
  Business     Revenue Cloud quote template (Revenue_Lifecycle_Management), tokens = tags of the context definition
               NF_ProposalContext (SalesTransactionContext extension, QuoteEntitiesMapping); line rows repeat over
               {{#SalesTransactionItem}}.
Money values are display formulas on Quote / QuoteLineItem (NF_*_Display__c). DocuSign places the signature and
date on the white anchor text [[SIGN_CUSTOMER]] / [[DATE_CUSTOMER]].

Run: <venv>/python scripts/docgen/build_templates.py   (needs python-docx)
"""
import os
from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'docs', 'templates')
FONT = 'Arial'
WHITE = RGBColor(0xFF, 0xFF, 0xFF)


def hex_rgb(h):
    return RGBColor.from_string(h.lstrip('#').upper())


def base_document(margins_cm=2.0):
    d = Document()
    st = d.styles['Normal']
    st.font.name = FONT
    st.element.rPr.rFonts.set(qn('w:eastAsia'), FONT)
    st.font.size = Pt(10)
    st.paragraph_format.space_after = Pt(4)
    st.paragraph_format.line_spacing = 1.15
    for s in d.sections:
        s.left_margin = s.right_margin = Cm(margins_cm)
        s.top_margin = Cm(1.6)
        s.bottom_margin = Cm(1.6)
    return d


def para(container, text='', size=10, bold=False, color=None, align=None, after=4, before=0, italic=False):
    p = container.add_paragraph()
    p.paragraph_format.space_after = Pt(after)
    p.paragraph_format.space_before = Pt(before)
    if align:
        p.alignment = align
    if text:
        run(p, text, size, bold, color, italic)
    return p


def run(p, text, size=10, bold=False, color=None, italic=False):
    r = p.add_run(text)
    r.font.name = FONT
    r.font.size = Pt(size)
    r.bold = bold
    r.italic = italic
    if color:
        r.font.color.rgb = color if isinstance(color, RGBColor) else hex_rgb(color)
    return r


def shade(cell, fill):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill.lstrip('#'))
    tcPr.append(shd)


def borders(table, color='E4E1EE', size=4, inside=True):
    tbl = table._tbl
    tblPr = tbl.tblPr
    b = OxmlElement('w:tblBorders')
    edges = ['top', 'left', 'bottom', 'right'] + (['insideH', 'insideV'] if inside else [])
    for edge in ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']:
        e = OxmlElement(f'w:{edge}')
        if edge in edges:
            e.set(qn('w:val'), 'single')
            e.set(qn('w:sz'), str(size))
            e.set(qn('w:color'), color)
        else:
            e.set(qn('w:val'), 'nil')
        b.append(e)
    tblPr.append(b)


def cell_text(cell, text, size=9.5, bold=False, color=None, align=None, fill=None):
    cell.text = ''
    p = cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(0)
    if align:
        p.alignment = align
    run(p, text, size, bold, color)
    if fill:
        shade(cell, fill)
    return p


def col_widths(table, widths_cm):
    for row in table.rows:
        for i, w in enumerate(widths_cm):
            row.cells[i].width = Cm(w)


def page_break(doc):
    """Terms and signatures start on their own page so the signature block never splits."""
    p = para(doc, after=0)
    p.add_run().add_break(WD_BREAK.PAGE)


def anchors(container):
    """DocuSign anchors, invisible in the PDF."""
    p = para(container, after=0)
    run(p, '[[SIGN_CUSTOMER]]', 6, color=WHITE)
    return p


def footer(doc, text, color):
    for s in doc.sections:
        p = s.footer.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run(p, text, 7.5, color=color)


# ── Residential: Home Service Agreement ─────────────────────────────────────

def residential():
    PURPLE, INK, MUTED, SOFT, TEAL = '5B2BE0', '1B1340', '5F6577', 'EFEAFD', '00796B'
    d = base_document(2.0)

    # Header band
    band = d.add_table(rows=1, cols=2)
    band.alignment = WD_TABLE_ALIGNMENT.CENTER
    borders(band, inside=False, color=PURPLE, size=0)
    c0, c1 = band.rows[0].cells
    shade(c0, PURPLE)
    shade(c1, PURPLE)
    p = cell_text(c0, 'NovaFiber', 20, True, WHITE)
    p2 = c0.add_paragraph()
    run(p2, 'Home Service Agreement', 10.5, False, 'E6DDFF')
    p = cell_text(c1, 'Agreement {{AgreementNumber}}', 9, True, WHITE, WD_ALIGN_PARAGRAPH.RIGHT)
    p2 = c1.add_paragraph()
    p2.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    run(p2, 'Issued {{AgreementDate}}', 9, False, 'E6DDFF')
    col_widths(band, [10.5, 6.5])

    para(d, 'Hi {{CustomerFirstName}}, welcome to NovaFiber.', 15, True, INK, before=14, after=2)
    para(d, 'This agreement puts everything about your home service on one page: what you are getting, what it costs '
            'and the promises we make to each other. It is written in plain language. Please read it before you sign.',
         10, color=MUTED, after=10)

    # Summary grid
    grid = d.add_table(rows=2, cols=3)
    borders(grid, color='E4E1EE')
    facts = [('Account holder', '{{CustomerName}}'), ('Service address', '{{ServiceAddress}}'), ('Quote', '{{QuoteNumber}}'),
             ('Email', '{{CustomerEmail}}'), ('Phone', '{{CustomerPhone}}'), ('Service starts', 'On the day we install')]
    for i, (label, value) in enumerate(facts):
        c = grid.rows[i // 3].cells[i % 3]
        shade(c, 'FBFAFF')
        cell_text(c, label.upper(), 7.5, True, MUTED)
        p = c.add_paragraph()
        p.paragraph_format.space_after = Pt(2)
        run(p, value, 10, True, INK)
    col_widths(grid, [5.2, 6.6, 5.2])

    para(d, 'Your plan', 12.5, True, PURPLE, before=14, after=4)
    t = d.add_table(rows=3, cols=4)
    borders(t, color='E4E1EE')
    for i, h in enumerate(['Service', 'Qty', 'Monthly', 'One-time']):
        cell_text(t.rows[0].cells[i], h, 8.5, True, WHITE, WD_ALIGN_PARAGRAPH.RIGHT if i else None, PURPLE)
    row = t.rows[1].cells
    cell_text(row[0], '{{#Lines}}{{Name}}', 9.5, True, INK)
    row[0].add_paragraph().add_run('{{Detail}}').font.size = Pt(8)
    cell_text(row[1], '{{Quantity}}', 9.5, align=WD_ALIGN_PARAGRAPH.RIGHT)
    cell_text(row[2], '{{Monthly}}', 9.5, align=WD_ALIGN_PARAGRAPH.RIGHT)
    cell_text(row[3], '{{OneTime}}{{/Lines}}', 9.5, align=WD_ALIGN_PARAGRAPH.RIGHT)
    tot = t.rows[2].cells
    cell_text(tot[0], 'Total', 10, True, INK, fill=SOFT)
    cell_text(tot[1], '', fill=SOFT)
    cell_text(tot[2], '{{MonthlyTotal}}/mo', 10, True, PURPLE, WD_ALIGN_PARAGRAPH.RIGHT, SOFT)
    cell_text(tot[3], '{{OneTimeTotal}}', 10, True, INK, WD_ALIGN_PARAGRAPH.RIGHT, SOFT)
    col_widths(t, [9.4, 1.6, 3.0, 3.0])
    para(d, 'Prices include equipment rental shown above. Taxes and government fees are added to your bill.',
         8, color=MUTED, before=3, after=8, italic=True)

    # Promise boxes
    promises = d.add_table(rows=1, cols=3)
    borders(promises, inside=False, color='FFFFFF', size=0)
    for i, (title, body) in enumerate([
        ('No annual contract', 'Cancel any time with 30 days’ notice. No early termination fees.'),
        ('24-month price lock', 'Your monthly price for this plan will not go up for 24 months.'),
        ('30-day happiness', 'Not right for you? Cancel within 30 days and we refund the one-time charges.')]):
        c = promises.rows[0].cells[i]
        shade(c, 'E3F7F4')
        cell_text(c, title, 9.5, True, TEAL)
        p = c.add_paragraph()
        p.paragraph_format.space_after = Pt(4)
        run(p, body, 8.5, color=INK)
    col_widths(promises, [5.66, 5.66, 5.66])

    page_break(d)
    para(d, 'The fine print, in plain words', 12.5, True, PURPLE, before=0, after=4)
    terms = [
        ('Installation', 'A two-person NovaFiber crew installs and activates your service at the address above. You choose the '
                         'arrival window when you book; please make sure an adult (18+) is home and the crew can reach the outside wall.'),
        ('Equipment', 'Gateways, mesh units and set-top boxes stay NovaFiber property. Return them within 30 days after your '
                      'service ends or we charge their replacement cost.'),
        ('Billing', 'We bill monthly in advance from the day your service is activated. One-time charges appear on your first bill.'),
        ('Speeds', 'Plan speeds are the maximum wired speeds to your gateway. Wi-Fi speeds depend on your devices and home.'),
        ('Fair use and safety', 'Use the service lawfully and do not resell it. We may suspend service that harms the network or others.'),
        ('Privacy', 'We use your details to provide and bill the service and never sell them. See novafiber.example/privacy.'),
        ('Changes', 'You can change plans any time. We will tell you 30 days before any change to these terms.'),
        ('Law', 'This agreement is governed by the laws of the state of your service address ({{ServiceState}}).'),
    ]
    for i, (h, body) in enumerate(terms, 1):
        p = para(d, after=3)
        run(p, f'{i}. {h}. ', 9, True, INK)
        run(p, body, 9, color=INK)

    para(d, 'Signature', 12.5, True, PURPLE, before=18, after=4)
    sig = d.add_table(rows=2, cols=2)
    borders(sig, color='E4E1EE')
    c = sig.rows[0].cells[0]
    cell_text(c, 'ACCOUNT HOLDER SIGNATURE', 7.5, True, MUTED)
    p = c.add_paragraph()
    p.paragraph_format.space_before = Pt(10)
    run(p, '[[SIGN_CUSTOMER]]', 7, color=WHITE)
    c = sig.rows[0].cells[1]
    cell_text(c, 'DATE', 7.5, True, MUTED)
    p = c.add_paragraph()
    p.paragraph_format.space_before = Pt(10)
    run(p, '[[DATE_CUSTOMER]]', 7, color=WHITE)
    cell_text(sig.rows[1].cells[0], 'Name: {{CustomerName}}', 9, color=INK)
    cell_text(sig.rows[1].cells[1], 'For NovaFiber: Customer Operations', 9, color=INK)
    col_widths(sig, [11, 6])

    footer(d, 'NovaFiber Inc. (demo) · Home Service Agreement {{AgreementNumber}} · Generated by Salesforce Document Generation', MUTED)
    return d


# ── Business: Multi-site Proposal ───────────────────────────────────────────

def business():
    NAVY, TEAL, INK, MUTED, RULE, SOFT = '12233F', '00A693', '1E2733', '5B6676', 'D5DCE6', 'F2F5F9'
    d = base_document(2.2)

    # Cover page
    para(d, 'NOVAFIBER BUSINESS', 9, True, TEAL, before=60, after=2)
    para(d, 'Connectivity proposal', 30, True, NAVY, after=2)
    para(d, 'for {{NF_CompanyName}}', 18, False, INK, after=24)
    cover = d.add_table(rows=4, cols=2)
    borders(cover, color=RULE, inside=True)
    for i, (k, v) in enumerate([('Proposal', '{{NF_QuoteNumber}}'), ('Prepared', '{{NF_ProposalDate}}'),
                                 ('Valid until', '{{NF_ValidUntil}}'), ('Prepared by', '{{NF_PreparedBy}}')]):
        cell_text(cover.rows[i].cells[0], k.upper(), 8, True, MUTED, fill=SOFT)
        cell_text(cover.rows[i].cells[1], v, 10.5, True, INK)
    col_widths(cover, [4.5, 8])
    para(d, '{{NF_SiteCount}} sites · {{NF_StateList}}', 11, True, TEAL, before=24, after=2)
    para(d, 'Business fiber, dedicated internet, SD-WAN and voice, priced for each site’s state.', 10, color=MUTED, after=0)
    p = para(d, after=0)
    p.add_run().add_break(WD_BREAK.PAGE)

    def h1(n, text):
        p = para(d, before=10, after=4)
        run(p, f'{n}  ', 13, True, TEAL)
        run(p, text, 13, True, NAVY)

    h1('1', 'Executive summary')
    para(d, 'NovaFiber proposes to connect {{NF_SiteCount}} {{NF_CompanyName}} locations on its fiber network under one '
            'agreement and one bill. Each site has its own service bundle, installation visit and service location, and '
            'is priced for its state from NovaFiber’s location-based rate card.', 10, color=INK, after=6)
    kpi = d.add_table(rows=1, cols=3)
    borders(kpi, inside=False, color='FFFFFF', size=0)
    for i, (label, value) in enumerate([('Monthly recurring', '{{NF_MonthlyTotal}}'), ('One-time', '{{NF_OneTimeTotal}}'),
                                        ('36-month contract value', '{{NF_ContractValue}}')]):
        c = kpi.rows[0].cells[i]
        shade(c, NAVY)
        cell_text(c, label.upper(), 7.5, True, 'A9C1DD')
        p = c.add_paragraph()
        p.paragraph_format.space_after = Pt(4)
        run(p, value, 15, True, WHITE)
    col_widths(kpi, [5.53, 5.53, 5.53])

    h1('2', 'Services by site')
    t = d.add_table(rows=3, cols=6)
    borders(t, color=RULE)
    for i, h in enumerate(['Site', 'State', 'Service', 'Qty', 'Monthly', 'One-time']):
        cell_text(t.rows[0].cells[i], h, 8.5, True, WHITE, WD_ALIGN_PARAGRAPH.RIGHT if i >= 3 else None, NAVY)
    r = t.rows[1].cells
    cell_text(r[0], '{{#SalesTransactionItem}}{{NF_SiteName}}', 8.5, color=MUTED)
    cell_text(r[1], '{{NF_SiteState}}', 8.5, color=MUTED)
    cell_text(r[2], '{{ProductName}}', 9, True, INK)
    cell_text(r[3], '{{NF_Quantity}}', 9, align=WD_ALIGN_PARAGRAPH.RIGHT)
    cell_text(r[4], '{{NF_LineMonthly}}', 9, align=WD_ALIGN_PARAGRAPH.RIGHT)
    cell_text(r[5], '{{NF_LineOneTime}}{{/SalesTransactionItem}}', 9, align=WD_ALIGN_PARAGRAPH.RIGHT)
    tot = t.rows[2].cells
    cell_text(tot[0], 'Total', 9.5, True, NAVY, fill=SOFT)
    for k in (1, 2, 3):
        cell_text(tot[k], '', fill=SOFT)
    cell_text(tot[4], '{{NF_MonthlyTotal}}', 9.5, True, NAVY, WD_ALIGN_PARAGRAPH.RIGHT, SOFT)
    cell_text(tot[5], '{{NF_OneTimeTotal}}', 9.5, True, NAVY, WD_ALIGN_PARAGRAPH.RIGHT, SOFT)
    col_widths(t, [3.2, 1.2, 6.0, 1.2, 2.5, 2.5])
    para(d, 'Prices are per site and per state (location-based rate card). Taxes, surcharges and regulatory fees are extra.',
         8, color=MUTED, before=3, italic=True)

    h1('3', 'Service levels')
    t = d.add_table(rows=5, cols=4)
    borders(t, color=RULE)
    rows = [('Service', 'Availability', 'Time to repair', 'Support'),
            ('Dedicated Internet', '99.95%', '4 hours', '24 × 7 NOC, proactive monitoring'),
            ('Business Fiber', '99.9%', '8 hours', '24 × 7 business support'),
            ('SD-WAN', '99.99% (dual path)', '4 hours (edge swap)', 'Managed, portal and reporting'),
            ('Business Voice', '99.99%', '4 hours', 'Number porting and admin portal')]
    for i, row in enumerate(rows):
        for j, v in enumerate(row):
            if i == 0:
                cell_text(t.rows[i].cells[j], v, 8.5, True, WHITE, fill=NAVY)
            else:
                cell_text(t.rows[i].cells[j], v, 9, j == 0, INK, fill=SOFT if i % 2 == 0 else None)
    col_widths(t, [4.2, 3.6, 3.6, 5.5])
    para(d, 'Service credits of 5% of the affected site’s monthly charge per full hour beyond the time to repair, up to 50%.',
         8.5, color=MUTED, before=3)

    page_break(d)
    h1('4', 'Commercial terms')
    for h, body in [
        ('Term', '36 months per site, starting on that site’s activation date.'),
        ('Billing', 'One consolidated invoice per month, in arrears, payable within 30 days. Each site’s charges start at activation.'),
        ('Installation', 'One scheduled visit per site by a NovaFiber crew from that state; site access and power are the customer’s responsibility.'),
        ('Changes', 'Sites can be added at the then-current state rates. Upgrades during the term keep the remaining term.'),
        ('Early termination', '50% of the remaining monthly charges of the terminated site.'),
        ('Validity', 'This proposal is valid until {{NF_ValidUntil}}. Signing it accepts these terms and authorises NovaFiber to order the services.'),
    ]:
        p = para(d, after=3)
        run(p, h + '. ', 9, True, NAVY)
        run(p, body, 9, color=INK)

    h1('5', 'Acceptance')
    para(d, 'Signed for and on behalf of {{NF_CompanyName}} by an authorised signatory.', 9.5, color=INK, after=6)
    sig = d.add_table(rows=2, cols=3)
    borders(sig, color=RULE)
    for i, label in enumerate(['SIGNATURE', 'NAME', 'DATE']):
        cell_text(sig.rows[0].cells[i], label, 7.5, True, MUTED, fill=SOFT)
    c = sig.rows[1].cells[0]
    cell_text(c, '[[SIGN_CUSTOMER]]', 7, color=WHITE)
    # Salesforce Contracts e-signature: ESignatureConfig AnchorString "signHereTabs:nfSignHere,dateSignedTabs:nfDateSigned"
    # places its tabs on \nfSignHere1\ and \nfDateSigned1\ (base + signer number between backslashes)
    run(c.add_paragraph(), '\\nfSignHere1\\', 7, color=WHITE)
    c.add_paragraph().paragraph_format.space_before = Pt(10)
    cell_text(sig.rows[1].cells[1], '{{NF_SignerName}}', 9.5, True, INK)
    c = sig.rows[1].cells[2]
    cell_text(c, '[[DATE_CUSTOMER]]', 7, color=WHITE)
    run(c.add_paragraph(), '\\nfDateSigned1\\', 7, color=WHITE)
    col_widths(sig, [7.5, 5.5, 3.6])

    footer(d, 'NovaFiber Business · Proposal {{NF_QuoteNumber}} for {{NF_CompanyName}} · Confidential · Generated by Salesforce Document Generation', MUTED)
    return d


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    residential().save(os.path.join(OUT, 'NovaFiber_Residential_Service_Agreement.docx'))
    business().save(os.path.join(OUT, 'NovaFiber_Business_Proposal.docx'))
    print('templates written to', os.path.abspath(OUT))
