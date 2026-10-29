"""
Builds and deploys a NovaFiber CML constraint model.

    python scripts/cml/nf_cml.py scripts/cml/NF_Residential_Rules.json [--dry-run]

The JSON spec holds only the business rules:
    "model":      ExpressionSetDefinition API name (deploy force-app/.../expressionSetDefinition first)
    "bundles":    { "PRODUCT-CODE": "CmlType" }   bundles that carry rules
    "components": { "PRODUCT-CODE": "CmlType" }   options the rules name (others get a generated type name)
    "rules":      { "CmlType": ["require(...);", ...] }

The engine needs every component of a bundle declared in its type, so the script reads each bundle's
ProductRelatedComponents and generates one relation per component group (Equipment -> equipment, Add-ons -> addons,
...), writes the full model to <model>.cml next to the spec, and maps it to the catalog with
ExpressionSetConstraintObj records (a Type per product, a Port per ProductRelatedComponent).

Deploying uploads the CML to ExpressionSetDefinitionVersion.ConstraintModel, replaces the mappings, then deactivates
and activates the version in the Constraint Builder (nf_cml_activate.mjs, Playwright: `npm install` in scripts/cml
once). Only the builder compiles the model: ExpressionSetVersion.IsActive flips the flag but the configurator keeps
running the previously compiled model. Re-run after every change. The builder's Sync button deletes Port records.
"""
import base64, json, os, re, subprocess, sys, urllib.parse

ORG = 'RCPOC'
API = 'v66.0'


def call(method, path, body=None):
    """REST call through the sf CLI (it keeps the access token to itself)."""
    cmd = ['sf', 'api', 'request', 'rest', path, '--method', method, '-o', ORG]
    data = None
    if body is not None:
        cmd += ['--body', '-']
        data = json.dumps(body)
    res = subprocess.run(' '.join(f'"{c}"' if ' ' in c or '&' in c or '?' in c else c for c in cmd),
                         shell=True, capture_output=True, text=True, encoding='utf-8', input=data)
    out = res.stdout.strip()
    if res.returncode != 0 or '"errorCode"' in out[:300]:
        raise SystemExit(f'{method} {path} -> {out[:800]} {res.stderr[-400:]}')
    return json.loads(out) if out else None


def query(soql):
    return call('GET', f'/services/data/{API}/query?q=' + urllib.parse.quote(soql))['records']


def relation_name(group):
    words = re.findall(r'[A-Za-z0-9]+', (group or 'Components').replace('-', ''))
    return words[0].lower() + ''.join(w.capitalize() for w in words[1:])


def build(spec):
    """Generates the CML text and the ExpressionSetConstraintObj rows (Type/Port) from the spec and the catalog.

    The engine needs, per relation, a Port for every subtype of the relation's type, and a product can be the Type of
    only one CML type. So each distinct set of group members gets one base type (shared by the bundles whose group
    holds exactly those products) and each product one leaf type; a product in two different member sets is an error
    (keep such bundles out of the model).
    """
    bundles, components = spec['bundles'], dict(spec.get('components', {}))
    codes = ','.join(f"'{c}'" for c in bundles)
    prcs = query('SELECT Id, ParentProduct.ProductCode, ChildProduct.ProductCode, ChildProductId, ProductComponentGroup.Name, '
                 'MaxQuantity FROM ProductRelatedComponent WHERE ParentProduct.ProductCode IN (' + codes + ') '
                 'ORDER BY ParentProduct.ProductCode, ProductComponentGroup.Name, ChildProduct.ProductCode')
    product_ids = {r['ProductCode']: r['Id'] for r in query('SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN ('
                                                             + codes + ')')}
    for r in prcs:
        code = r['ChildProduct']['ProductCode']
        components.setdefault(code, 'NF_' + re.sub(r'[^A-Za-z0-9]', '_', code))
        product_ids[code] = r['ChildProductId']
    missing = set(bundles) - product_ids.keys()
    if missing:
        raise SystemExit(f'Unknown bundle codes: {sorted(missing)}')

    groups = {}      # bundle code -> {relation: [prc rows]}
    for r in prcs:
        rel = relation_name((r['ProductComponentGroup'] or {}).get('Name'))
        groups.setdefault(r['ParentProduct']['ProductCode'], {}).setdefault(rel, []).append(r)
    bases = {}       # frozenset of member codes -> base type name
    base_of = {}     # member code -> its member set
    for code in bundles:
        for rel, rows in groups.get(code, {}).items():
            members = frozenset(r['ChildProduct']['ProductCode'] for r in rows)
            for m in members:
                if base_of.setdefault(m, members) != members:
                    raise SystemExit(f'{m} is in two different component groups ({sorted(base_of[m])} and {sorted(members)}); '
                                     'one CML model cannot hold both bundles.')
            bases.setdefault(members, 'NFGroup_' + rel + ('' if not any(v.startswith('NFGroup_' + rel) for v in bases.values())
                                                         else str(len(bases))))

    lines = [f'// {spec["model"]}: generated by scripts/cml/nf_cml.py from {spec["source"]}. Edit the spec, not this file.',
             '// One relation per component group; rules come from the spec.', '', 'type LineItem;', '']
    maps = []
    for code, btype in bundles.items():
        lines.append(f'// {code}')
        lines.append(f'type {btype} : LineItem {{')
        for rel, rows in groups.get(code, {}).items():
            upper = sum(max(int(r['MaxQuantity'] or 1), 1) for r in rows)
            base = bases[frozenset(r['ChildProduct']['ProductCode'] for r in rows)]
            lines.append(f'    relation {rel} : {base}[0..{upper}];')
            maps.extend(('Port', rel, r['Id']) for r in rows)
        for rule in spec['rules'].get(btype, []):
            lines.append('    ' + rule)
        lines.append('}')
        lines.append('')
        maps.append(('Type', btype, product_ids[code]))
    for members, base in bases.items():
        lines.append(f'type {base} : LineItem {{}}')
        for m in sorted(members):
            lines.append(f'type {components[m]} : {base} {{}}   // {m}')
            maps.append(('Type', components[m], product_ids[m]))
    return '\n'.join(lines) + '\n', maps


def main():
    spec_path = sys.argv[1]
    dry = '--dry-run' in sys.argv
    spec = json.load(open(spec_path, encoding='utf-8'))
    spec['source'] = os.path.basename(spec_path)
    model = spec['model']
    cml, maps = build(spec)
    out_path = os.path.join(os.path.dirname(os.path.abspath(spec_path)), model + '.cml')
    open(out_path, 'w', encoding='utf-8', newline='\n').write(cml)
    types = sum(1 for m in maps if m[0] == 'Type')
    print(f'{out_path}: {len(cml)} chars, {types} types, {len(maps) - types} ports')
    if dry:
        return

    esv = query(f"SELECT Id, ExpressionSet.ExpressionSetDefinitionId FROM ExpressionSetVersion WHERE ApiName = '{model}_V1'")
    ver = query(f"SELECT Id, MasterLabel FROM ExpressionSetDefinitionVersion WHERE DeveloperName = '{model}_V1'")
    if not esv or not ver:
        raise SystemExit(f'Deploy the ExpressionSetDefinition {model} first.')
    call('PATCH', f"/services/data/{API}/sobjects/ExpressionSetDefinitionVersion/{ver[0]['Id']}",
         {'ConstraintModel': base64.b64encode(cml.encode()).decode()})

    es = query(f"SELECT Id FROM ExpressionSet WHERE ApiName = '{model}'")[0]['Id']
    old = [r['Id'] for r in query(f"SELECT Id FROM ExpressionSetConstraintObj WHERE ExpressionSetId = '{es}'")]
    if old:
        res = subprocess.run(f'sf apex run -o {ORG}', shell=True, capture_output=True, text=True, encoding='utf-8',
                             input=f"delete [SELECT Id FROM ExpressionSetConstraintObj WHERE ExpressionSetId = '{es}'];")
        if 'Executed successfully' not in res.stdout:
            raise SystemExit('Could not delete the old mappings: ' + res.stdout[-600:])
    rows = [{'attributes': {'type': 'ExpressionSetConstraintObj'}, 'ExpressionSetId': es, 'ConstraintModelTagType': kind,
             'ConstraintModelTag': tag, 'ReferenceObjectId': ref} for kind, tag, ref in maps]
    for i in range(0, len(rows), 200):
        res = call('POST', f'/services/data/{API}/composite/sobjects', {'allOrNone': True, 'records': rows[i:i + 200]})
        bad = [x for x in res if not x.get('success')]
        if bad:
            raise SystemExit(f'Mapping insert failed: {bad[:3]}')
    print(f'Uploaded; {len(old)} old mappings replaced by {len(rows)}')

    # Only the Constraint Builder compiles the CML into the runtime model (the IsActive flag alone does not).
    ctx = query("SELECT ContextDefinitionId FROM ExpressionSetDefinitionContextDefinition WHERE ExpressionSetDefinitionId = '"
                + esv[0]['ExpressionSet']['ExpressionSetDefinitionId'] + "'")[0]['ContextDefinitionId']
    here = os.path.dirname(os.path.abspath(__file__))
    res = subprocess.run(['node', os.path.join(here, 'nf_cml_activate.mjs'), es, esv[0]['Id'], ver[0]['MasterLabel'], ctx],
                         cwd=here, capture_output=True, text=True, encoding='utf-8', env=dict(os.environ, NF_ORG=ORG))
    print(res.stdout.strip() or res.stderr.strip()[-800:])
    if res.returncode != 0:
        raise SystemExit(f'{model}_V1 was not activated (see the builder message above).')


if __name__ == '__main__':
    main()
