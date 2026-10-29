"""
Adds the NovaFiber business proposal attributes to the NF_ProposalContext context definition (an extension of
SalesTransactionContext__stdctx), for the "NovaFiber Business Proposal" Word template (Context Service tokens).

  SalesTransaction (Quote)          NF_CompanyName, NF_QuoteNumber, NF_ProposalDate, NF_ValidUntil, NF_PreparedBy,
                                    NF_SiteCount, NF_StateList, NF_MonthlyTotal, NF_OneTimeTotal, NF_ContractValue,
                                    NF_SignerName
  SalesTransactionItem (line)       NF_SiteName, NF_SiteState, NF_Quantity, NF_LineMonthly, NF_LineOneTime

Each attribute has a tag of the same name (the template token). QuoteEntitiesMapping hydrates them from Quote /
QuoteLineItem fields (formula and roll-up fields NF_*__c); every other mapping of those nodes gets an input-only
mapping, because an attribute missing from any mapping breaks hydration of the whole context.

Usage: sf project retrieve start -m ContextDefinition:NF_ProposalContext  →  python this.py  →  deploy  →  activate.
"""
import re
import sys

PATH = r'C:/Dev Projects/RCPOC/force-app/main/default/contextDefinitions/NF_ProposalContext.contextDefinition-meta.xml'

HEADER = [  # attribute, data type, Quote field
    ('NF_CompanyName', 'string', 'NF_Company_Name__c'),
    ('NF_QuoteNumber', 'string', 'QuoteNumber'),
    ('NF_ProposalDate', 'string', 'NF_Proposal_Date_Display__c'),
    ('NF_ValidUntil', 'string', 'NF_Valid_Until_Display__c'),
    ('NF_PreparedBy', 'string', 'NF_Prepared_By__c'),
    ('NF_SiteCount', 'string', 'NF_Site_Count_Display__c'),
    ('NF_StateList', 'string', 'NF_State_List__c'),
    ('NF_MonthlyTotal', 'string', 'NF_Monthly_Total_Display__c'),
    ('NF_OneTimeTotal', 'string', 'NF_One_Time_Total_Display__c'),
    ('NF_ContractValue', 'string', 'NF_Contract_Value_Display__c'),
    ('NF_SignerName', 'string', 'NF_Signer_Name__c'),
]
ITEM = [  # attribute, data type, QuoteLineItem field
    ('NF_SiteName', 'string', 'NF_Site_Name__c'),
    ('NF_SiteState', 'string', 'NF_Site_State__c'),
    ('NF_Quantity', 'string', 'NF_Quantity_Display__c'),
    ('NF_LineMonthly', 'string', 'NF_Monthly_Display__c'),
    ('NF_LineOneTime', 'string', 'NF_One_Time_Display__c'),
]
NODES = {'SalesTransaction': (HEADER, 'Quote'), 'SalesTransactionItem': (ITEM, 'QuoteLineItem')}


def attribute_xml(name, data_type, indent):
    p = ' ' * indent
    return (f'{p}<contextAttributes>\n{p}    <contextTags>\n{p}        <title>{name}</title>\n{p}    </contextTags>\n'
            f'{p}    <customMappingAllowed>false</customMappingAllowed>\n{p}    <dataType>{data_type}</dataType>\n'
            f'{p}    <fieldType>inputoutput</fieldType>\n{p}    <key>false</key>\n{p}    <title>{name}</title>\n'
            f'{p}    <transient>false</transient>\n{p}    <value>false</value>\n{p}</contextAttributes>\n')


def mapping_xml(name, obj, field, indent):
    p = ' ' * indent
    hydration = '' if field is None else (
        f'{p}    <contextAttrHydrationDetails>\n{p}        <objectName>{obj}</objectName>\n'
        f'{p}        <queryAttribute>{field}</queryAttribute>\n{p}    </contextAttrHydrationDetails>\n')
    return (f'{p}<contextAttributeMappings>\n{hydration}{p}    <contextAttribute>{name}</contextAttribute>\n'
            f'{p}    <contextInputAttributeName>{name}</contextInputAttributeName>\n{p}</contextAttributeMappings>\n')


def main():
    s = open(PATH, encoding='utf8').read()
    if 'NF_CompanyName' in s:
        print('already applied')
        return
    lines = s.split('\n')
    out = []
    i = 0
    mapping_title = None
    # Mapping titles appear at the END of each <contextMappings> block: pre-scan block → title.
    titles = {}
    start = None
    for n, line in enumerate(lines):
        if line.strip() == '<contextMappings>':
            start = n
        m = re.match(r'^ {12}<title>(.*)</title>$', line)
        if start is not None and m:
            titles[start] = m.group(1)
        if line.strip() == '</contextMappings>':
            start = None
    current_mapping = None
    added_nodes, added_maps = 0, 0
    node_stack = []
    while i < len(lines):
        line = lines[i]
        st = line.strip()
        if st == '<contextMappings>':
            current_mapping = titles.get(i)
        if st == '</contextMappings>':
            current_mapping = None
        # Node mapping: insert our attribute mappings just before </contextNodeMappings> of the right node.
        if st == '</contextNodeMappings>' and current_mapping:
            # look back for <contextNode>X</contextNode> in this node mapping
            j = len(out) - 1
            node = None
            while j >= 0 and '<contextNodeMappings>' not in out[j]:
                m = re.match(r'^\s*<contextNode>(\w+)</contextNode>$', out[j])
                if m and node is None and out[j].startswith(' ' * 16 + '<contextNode>'):
                    node = m.group(1)
                j -= 1
            if node in NODES:
                attrs, obj = NODES[node]
                # insert before the <contextNode> line (attribute mappings come first)
                k = len(out) - 1
                while not out[k].startswith(' ' * 16 + '<contextNode>'):
                    k -= 1
                block = ''.join(mapping_xml(a, obj, f if current_mapping == 'QuoteEntitiesMapping' else None, 16) for a, _, f in attrs)
                out[k:k] = block.rstrip('\n').split('\n')
                added_maps += 1
        out.append(line)
        i += 1
    # Node definitions: add attributes to the SalesTransaction / SalesTransactionItem <contextNodes>.
    text = '\n'.join(out)
    for node, (attrs, _) in NODES.items():
        # the node's own <title> sits after its attributes; insert before the node's first <contextTags>/<title> pair
        pattern = re.compile(r'(\n( {12})<contextTags>\n {16}<inheritedFrom>[^\n]*</inheritedFrom>\n {16}<title>' + node
                             + r'</title>\n {12}</contextTags>\n {12}<customMappingAllowed>)')
        m = pattern.search(text)
        if not m:
            sys.exit('node not found: ' + node)
        indent = len(m.group(2))
        block = '\n' + ''.join(attribute_xml(a, t, indent) for a, t, _ in attrs).rstrip('\n')
        text = text[:m.start()] + block + text[m.start():]
        added_nodes += 1
    open(PATH, 'w', encoding='utf8').write(text)
    print(f'nodes {added_nodes}, node mappings {added_maps}')


if __name__ == '__main__':
    main()
