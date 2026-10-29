"""
Registers the NovaFiber Word templates as native Salesforce document templates (idempotent; rerun after editing
docs/templates/*.docx or the mappings below).

  NovaFiber Home Service Agreement   Salesforce Contracts template, Data Mapper token mapping
      NFHomeAgreementExtract  Contract → Account, signer Contact, source Quote, its QuoteLineItems
      NFHomeAgreementTransform  extract output → template tokens
  NovaFiber Business Proposal        Revenue Cloud quote template, Context Service token mapping
      NF_ProposalContext (SalesTransactionContext extension) + QuoteEntitiesMapping

Learned the hard way (Data Mapper records written outside the designer):
  * every output mapping uses OutputCreationSequence 1 (each distinct value starts a separate output object)
  * extraction steps chain through FilterValue paths like Contract:AccountId; relationship fields use dots
    (Line:Product2.Name); the template needs a transform mapper as well as the extract
  * templates need their .docx linked through DocumentTemplateContentDoc and a TokenList
    ("Token,List:Token") set AFTER the file is linked (linking a template that already has a TokenList fails);
    fields can only change while the template is inactive

Run (from the project root): python scripts/docgen/setup_templates.py
"""
import base64
import json
import os
import subprocess
import tempfile

ORG = 'RCPOC'
ROOT = os.path.join(os.path.dirname(__file__), '..', '..')
TEMPLATES = os.path.join(ROOT, 'docs', 'templates')
API = '/services/data/v66.0'
ENV = dict(os.environ, MSYS_NO_PATHCONV='1')

AGREEMENT = {
    'name': 'NovaFiber Home Service Agreement',
    'file': 'NovaFiber_Residential_Service_Agreement.docx',
    'fields': {
        'Type': 'MicrosoftWord', 'UsageType': 'Contract_Lifecycle_Management', 'TokenMappingType': 'JSON',
        'TokenMappingMethodType': 'OmniDataTransform', 'ExtractOmniDataTransformName': 'NFHomeAgreementExtract',
        'MapperOmniDataTransformName': 'NFHomeAgreementTransform', 'DocumentGenerationMechanism': 'ServerSide',
    },
}
PROPOSAL = {
    'name': 'NovaFiber Business Proposal',
    'file': 'NovaFiber_Business_Proposal.docx',
    'fields': {
        'Type': 'MicrosoftWord', 'UsageType': 'Revenue_Lifecycle_Management', 'TokenMappingType': 'JSON',
        'TokenMappingMethodType': 'ContextService', 'ContextDefinitionName': 'NF_ProposalContext',
        'ContextMappingName': 'QuoteEntitiesMapping', 'DocumentGenerationMechanism': 'ServerSide',
    },
    'tokens': ['NF_CompanyName', 'NF_QuoteNumber', 'NF_ProposalDate', 'NF_ValidUntil', 'NF_PreparedBy', 'NF_SiteCount',
               'NF_StateList', 'NF_MonthlyTotal', 'NF_OneTimeTotal', 'NF_ContractValue', 'NF_SignerName',
               'SalesTransactionItem:NF_SiteName', 'SalesTransactionItem:NF_SiteState', 'SalesTransactionItem:ProductName',
               'SalesTransactionItem:NF_Quantity', 'SalesTransactionItem:NF_LineMonthly', 'SalesTransactionItem:NF_LineOneTime'],
}

# Data Mapper: extraction steps (object, filter field, filter value path, output path)
STEPS = [
    ('Contract', 'Id', 'Id', 'Contract'),
    ('Account', 'Id', 'Contract:AccountId', 'Acct'),
    ('Contact', 'Id', 'Contract:CustomerSignedId', 'Signer'),
    ('Quote', 'Id', 'Contract:SourceQuoteId', 'Quote'),
    ('QuoteLineItem', 'QuoteId', 'Contract:SourceQuoteId', 'Line'),
]
# extract path → token
OUTPUTS = {
    'Contract:ContractNumber': 'AgreementNumber', 'Contract:NF_Start_Date_Display__c': 'AgreementDate',
    'Contract:AccountId': 'AccountId', 'Contract:SourceQuoteId': 'SourceQuoteId', 'Contract:CustomerSignedId': 'SignerId',
    'Signer:FirstName': 'CustomerFirstName', 'Signer:Name': 'CustomerName', 'Signer:Email': 'CustomerEmail',
    'Signer:Phone': 'CustomerPhone', 'Acct:NF_Service_Address__c': 'ServiceAddress', 'Acct:ShippingState': 'ServiceState',
    'Quote:QuoteNumber': 'QuoteNumber', 'Quote:NF_Monthly_Total_Display__c': 'MonthlyTotal',
    'Quote:NF_One_Time_Total_Display__c': 'OneTimeTotal',
    'Line:Product2.Name': 'Lines:Name', 'Line:Product2.Description': 'Lines:Detail', 'Line:NF_Quantity_Display__c': 'Lines:Quantity',
    'Line:NF_Monthly_Display__c': 'Lines:Monthly', 'Line:NF_One_Time_Display__c': 'Lines:OneTime',
}
INTERNAL = {'AccountId', 'SourceQuoteId', 'SignerId'}
AGREEMENT['tokens'] = [t for t in OUTPUTS.values() if t not in INTERNAL]


def sf(*args, body=None):
    cmd = ['sf', *args, '-o', ORG]
    tmp = None
    if body is not None:
        tmp = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False, encoding='utf8')
        json.dump(body, tmp)
        tmp.close()
        cmd += ['--body', '@' + tmp.name]
    r = subprocess.run(' '.join(f'"{c}"' if ' ' in c else c for c in cmd), capture_output=True, text=True, shell=True, env=ENV, encoding='utf8')
    if tmp:
        os.unlink(tmp.name)
    out = r.stdout
    i = min([k for k in (out.find('{'), out.find('[')) if k >= 0], default=-1)
    return json.loads(out[i:]) if i >= 0 and out[i:].strip() else None


def rest(method, path, body=None):
    return sf('api', 'request', 'rest', API + path, '--method', method, body=body)


def query(soql):
    return rest('GET', '/query?q=' + soql.replace(' ', '+').replace("'", '%27'))['records']


def apex(code):
    with tempfile.NamedTemporaryFile('w', suffix='.apex', delete=False, encoding='utf8') as f:
        f.write(code)
    r = subprocess.run(f'sf apex run -o {ORG} -f "{f.name}"', capture_output=True, text=True, shell=True, encoding='utf8')
    os.unlink(f.name)
    if 'Compiled successfully' not in r.stdout or 'Executed successfully' not in r.stdout:
        raise SystemExit('Apex failed:\n' + r.stdout[-2000:] + r.stderr[-1000:])


def data_mappers():
    def item(name, dm, **kw):
        fields = ', '.join(f"{k} = {repr(v) if not isinstance(v, str) else chr(39) + v + chr(39)}" for k, v in kw.items())
        return f"items.add(new OmniDataTransformItem(Name = '{name}', OmniDataTransformationId = {dm}.Id, {fields}));"
    lines = []
    for n, (obj, field, value, path) in enumerate(STEPS, 1):
        lines.append(item(f's{n}', 'ex', InputObjectName=obj, InputObjectQuerySequence=n, FilterGroup=0, InputFieldName=field,
                          FilterOperator='=', FilterValue=value, OutputObjectName='json', OutputFieldName=path, OutputCreationSequence=0))
    for n, (src, token) in enumerate(OUTPUTS.items(), 1):
        lines.append(item(f'o{n}', 'ex', InputObjectName='json', InputFieldName=src, OutputObjectName='json', OutputFieldName=token,
                          OutputCreationSequence=1, InputObjectQuerySequence=0))
    for n, token in enumerate(AGREEMENT['tokens'], 1):
        lines.append(item(f't{n}', 'tr', InputObjectName='json', InputFieldName=token, OutputObjectName='json', OutputFieldName=token,
                          OutputCreationSequence=1, InputObjectQuerySequence=0))
    code = f"""
for (DocumentTemplate t : [SELECT Id FROM DocumentTemplate WHERE Name = '{AGREEMENT['name']}' AND IsActive = true]) {{
    t.IsActive = false; t.Status = 'Draft'; update t;
}}
delete [SELECT Id FROM OmniDataTransform WHERE Name IN ('NFHomeAgreementExtract', 'NFHomeAgreementTransform')];
OmniDataTransform ex = new OmniDataTransform(Name = 'NFHomeAgreementExtract', Type = 'Extract', InputType = 'JSON', OutputType = 'JSON',
    IsActive = false, VersionNumber = 1, IsManagedUsingStdDesigner = true,
    Description = 'NovaFiber Home Service Agreement: Contract (input Id) → account, signer, source quote and its lines.');
OmniDataTransform tr = new OmniDataTransform(Name = 'NFHomeAgreementTransform', Type = 'Transform', InputType = 'JSON', OutputType = 'JSON',
    IsActive = false, VersionNumber = 1, IsManagedUsingStdDesigner = true,
    Description = 'NovaFiber Home Service Agreement: extract output → Word template tokens.');
insert new List<OmniDataTransform>{{ ex, tr }};
List<OmniDataTransformItem> items = new List<OmniDataTransformItem>();
{chr(10).join(lines)}
insert items;
ex.IsActive = true; tr.IsActive = true;
update new List<OmniDataTransform>{{ ex, tr }};
"""
    apex(code)
    print('data mappers: NFHomeAgreementExtract, NFHomeAgreementTransform')


def template(spec):
    name = spec['name']
    rows = query(f"SELECT Id, IsActive FROM DocumentTemplate WHERE Name = '{name}' ORDER BY CreatedDate DESC LIMIT 1")
    fields = dict(spec['fields'])
    if rows:
        tid = rows[0]['Id']
        if rows[0]['IsActive']:
            rest('PATCH', f'/sobjects/DocumentTemplate/{tid}', {'IsActive': False, 'Status': 'Draft'})
        rest('PATCH', f'/sobjects/DocumentTemplate/{tid}', fields)
    else:
        res = rest('POST', '/sobjects/DocumentTemplate', dict(fields, Name=name, Status='Draft', IsActive=False, VersionNumber=1))
        tid = res['id']
    data = base64.b64encode(open(os.path.join(TEMPLATES, spec['file']), 'rb').read()).decode()
    links = query(f"SELECT ContentDocumentId FROM DocumentTemplateContentDoc WHERE DocumentTemplateId = '{tid}' LIMIT 1")
    if links:
        rest('POST', '/sobjects/ContentVersion', {'ContentDocumentId': links[0]['ContentDocumentId'], 'PathOnClient': spec['file'],
                                                  'VersionData': data, 'ReasonForChange': 'Template update'})
    else:
        rest('PATCH', f'/sobjects/DocumentTemplate/{tid}', {'TokenList': None})
        cv = rest('POST', '/sobjects/ContentVersion', {'Title': name, 'PathOnClient': spec['file'], 'VersionData': data})
        doc = query(f"SELECT ContentDocumentId FROM ContentVersion WHERE Id = '{cv['id']}'")[0]['ContentDocumentId']
        # REST, not Apex: the Apex insert fails with an internal error for Context Service templates
        rest('POST', '/sobjects/DocumentTemplateContentDoc', {'Name': name, 'DocumentTemplateId': tid, 'ContentDocumentId': doc,
                                                             'FileStageType': 'Original'})
    rest('PATCH', f'/sobjects/DocumentTemplate/{tid}', {'TokenList': ','.join(spec['tokens'])})
    rest('PATCH', f'/sobjects/DocumentTemplate/{tid}', {'IsActive': True, 'Status': 'Active'})
    print(f'template: {name} ({tid})')


if __name__ == '__main__':
    data_mappers()
    template(AGREEMENT)
    template(PROPOSAL)
