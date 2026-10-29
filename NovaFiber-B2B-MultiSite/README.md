# NovaFiber B2B: telco multi-site quote to activation

A business telco journey on Salesforce Revenue Cloud. **Umbrella Logistics** has four sites in four states (New York,
San Francisco, Chicago, Austin) and wants internet and phones at all of them on one deal. A NovaFiber account rep, working
in a guided selling console inside Salesforce:

- uploads the sites as a CSV and checks availability and the qualified business catalog for every site;
- sees each site priced for its own state (Revenue Cloud location-based pricing), configures dedicated internet, SD-WAN and
  cloud voice with CML rules that keep every site's cart valid, and copies a cart to the other sites with **Apply to all**;
- creates one quote with a service location and a line group per site;
- sends a proposal generated from the quote (Context Service + Word template) for signature through Salesforce Contracts and
  DocuSign;
- places the order and books an installer at every site from Field Service crew calendars.

Dynamic Revenue Orchestrator then runs a per-site fulfillment plan: order intake and billing once, and access, dedicated
circuit, equipment and managed-services lanes for every site, each at its own pace.

**How a site's state reaches the price:** `ItemLocationPrice__c` rows feed the standard Location Based Decision Table. The
standard Location Based Price step reads `ItemLocationState__c`, a custom attribute on the sales transaction line, which the
`ApexDmlAttributePreHook` (a `RevSignaling.SignalingApexProcessor` in the `QuoteProcedure` procedure plan) fills from the
line's site before pricing.

## Contents

- [How it works](#how-it-works)
- [1. What you need](#1-what-you-need)
- [2. Connect the org to itself](#2-connect-the-org-to-itself)
- [3. Extend the sales transaction context](#3-extend-the-sales-transaction-context)
- [4. Replace the placeholders](#4-replace-the-placeholders)
- [5. Deploy](#5-deploy)
- [6. Assign permissions](#6-assign-permissions)
- [7. Load the demo data](#7-load-the-demo-data)
- [8. Post-deployment steps](#8-post-deployment-steps)
- [9. Try it](#9-try-it)
- [Set up DocuSign](#set-up-docusign)
- [Troubleshooting](#troubleshooting)
- [What's in this folder](#whats-in-this-folder)

## How it works

```
Lightning tab: the rep console (nfGuidedSelling, multi-site mode)
        |  Lightning Web Components (nfGuidedSelling shell, nfMultiSite, nfInspector)
        v
  c/nfApi  ->  NF_JourneyController (one Apex gateway; every call returns data + a trace for the Journey Inspector)
        |
        +--> NF_ServiceabilityService ---- NF_Serviceability named credential --> network inventory (mock)
        +--> NF_OfferService / NF_QuoteService / NF_MultiSiteService -- NF_RevenueCloud named credential --> Revenue Cloud REST
        |       Product Discovery, Configurator (CML rules), Place Sales Transaction
        +--> NF_DocumentService / NF_ESignService --> Salesforce Contracts, Document Generation, DocuSign
        +--> NF_OrderService / NF_DroService --> createOrdersFromQuote, activate, submitOrder --> Dynamic Revenue Orchestrator
        |       DRO callout steps --> NF_DroCalloutProvider --> NF_FulfillmentSystems (mock) --> callback to NF_FulfillmentCallbackApi
        +--> NF_SchedulingService --> Field Service work orders, appointments and crews
```

Every Revenue Cloud call goes over REST through the `NF_RevenueCloud` named credential, which logs in to the org itself
with the client credentials flow. That way every user run the same code path, synchronously.

## 1. What you need

**Org.** A Salesforce org with:

| Capability | Used for |
| --- | --- |
| Revenue Cloud: Product Catalog Management, Pricing, Product Discovery | catalog, prices, qualified offers |
| Revenue Cloud: Product Configurator with **CML constraint models** | bundle rules (`NF_Business_Rules`) |
| Revenue Cloud: Transaction Management | quotes (Place Sales Transaction), orders |
| **Salesforce Contracts** with Document Generation | the business proposal (Revenue Cloud quote template, Context Service data) |
| **Dynamic Revenue Orchestrator** | decomposition and the fulfillment plan |
| **Field Service** (enabled in Setup) | install crews, work orders, appointments |
| **Context Service** | location pricing attribute, proposal data |
| Platform Cache, at least 1 MB of org cache | the `NFJourney` partition (address, offers and cart cache) |

A Revenue Cloud developer org or the Communications Cloud trial
(<https://developer.salesforce.com/free-trials/comparison/communications-cloud>) has everything above.
Set the org default language to English, then run **Salesforce Pricing Setup → Sync Pricing Data** once.

**On your machine.** Salesforce CLI (`sf`) v2, PowerShell 7, Python 3.10+ with `pip install python-docx`, Node 18+.

**Two HTTP mocks** for the outside systems. Import the Postman collections in [`mocks/`](mocks) and create a mock server
from each (Postman: collection → **⋯ → Mock collection**):

| Collection | Named credential | What it answers |
| --- | --- | --- |
| `NovaFiber_Serviceability_Mock` | `NF_Serviceability` | `POST /nf/serviceability?postalCode=…`, one example per demo ZIP code |
| `NovaFiber_Fulfillment_Systems_Mock` | `NF_FulfillmentSystems` | provisioning, logistics and billing calls from the DRO callout steps |

Demo ZIP codes: `10001` New York (fiber 2 Gig + 5G), `94105` San Francisco (fiber 1 Gig, new build), `60601` Chicago (copper
100), `30301` Atlanta (copper 60 + 5G), `73301` Austin (5G only), `99501` Anchorage (not serviceable). A `202` answer keeps a
DRO step in progress until a callback arrives; in this demo `NF_FulfillmentSimulator` plays the callbacks to
`/services/apexrest/nf/fulfillment/v1/callback`, so you don't have to.

## 2. Connect the org to itself

The `NF_RevenueCloud` named credential calls the org's own REST APIs as an integration user.

1. **Integration user.** Use an admin-level user (or a dedicated integration user) with Revenue Cloud, Contracts and
   DRO permissions. It runs every Revenue Cloud call.
2. **External Client App.** Setup → **External Client App Manager** → **New External Client App**, name `NF Revenue Cloud API`:
   - Enable OAuth, callback URL `https://login.salesforce.com/services/oauth2/callback`.
   - OAuth scopes: **Manage user data via APIs (api)**.
   - Enable **Client Credentials Flow**.
   - In the app's policies, set **Run As** (client credentials user) to the integration user.
   - Copy the **consumer key and secret**.
3. **External credential.** After you deploy (step 5), open Setup → **Named Credentials → External Credentials →
   NF Revenue Cloud API → Principals → NF_Integration → Edit** and paste the consumer key and secret. Keys are never
   stored in this repo.

## 3. Extend the sales transaction context

The CML models and the location pricing step use an extension of the standard **SalesTransactionContext** with one extra
attribute. Context extensions carry org-specific mappings, so create yours in the org rather than deploying one:

1. Setup → **Context Service → Context Definitions** → **SalesTransactionContext** → **Extend**. Name the extension
   `SalesTransactionContextExt_256` (or keep your own name and change `<contextDefinitions>` in
   `expressionSetDefinition/NF_*_Rules.expressionSetDefinition-meta.xml` to match).
2. On the **SalesTransactionItem** node, add the attribute `ItemLocationState__c`: data type *string*, field type
   *input/output*, with a tag of the same name.
3. In the **QuoteEntitiesMapping** and **OrderEntitiesMapping** mappings, map it as an input attribute named
   `ItemLocationState__c` (no object field: the pre-hook fills it at pricing time).
4. Activate the extension and select it as the sales transaction context in **Revenue Settings**.

The other two context definitions are deployed for you: `NF_NovaDiscoveryCtx` (Product Discovery: adds the address's
access technology and top download speed on the Account node) and `NF_ProposalContext` (the proposal data).

## 4. Replace the placeholders

| File (under `force-app/main/default`) | Placeholder | Put in |
| --- | --- | --- |
| `namedCredentials/NF_RevenueCloud.namedCredential-meta.xml` | `YOUR-MY-DOMAIN` | your My Domain |
| `externalCredentials/NF_RevenueCloud_API.externalCredential-meta.xml` | `YOUR-MY-DOMAIN` | your My Domain (token URL) |
| `namedCredentials/NF_Serviceability.namedCredential-meta.xml` | `YOUR-SERVICEABILITY-MOCK.example.com` | the serviceability mock URL |
| `namedCredentials/NF_FulfillmentSystems.namedCredential-meta.xml` | `YOUR-FULFILLMENT-MOCK.example.com` | the fulfillment mock URL |
| `platformEventSubscriberConfigs/NF_JourneyWorkerConfig…` | `YOUR-INTEGRATION-USERNAME@your-org.example` | the integration user's username |

## 5. Deploy

```bash
sf org login web --alias RCPOC --instance-url https://<mydomain>.my.salesforce.com
# 1) context definitions and custom objects first: the expression sets refer to them
sf project deploy start --metadata ContextDefinition CustomObject --target-org RCPOC
# 2) everything else
sf project deploy start --manifest manifest/package.xml --target-org RCPOC --test-level RunLocalTests
```

The scripts use the org alias `RCPOC`; to use another, pass `-Org` to `run-apex.ps1`, change `ORG` at the top of the
Python scripts, or set `NF_ORG`. When you redeploy Apex later, pause the hourly cleanup job first
(`scripts/apex/nf_00_pauseCleanup.apex`) and schedule it again afterwards (`nf_03_scheduleCleanup.apex`): a scheduled
job blocks deploying the classes it uses.

## 6. Assign permissions

| Permission set | Assign to |
| --- | --- |
| `NF_Guided_Selling` | the reps and admins who quote (the guided selling tab and multi-site mode) |
| `NF_Fulfillment_Ops` | admins and operations users who work the fulfillment timeline |

Each of them grants access to the `NF_RevenueCloud_API` external credential principal. Add the **NF Guided Selling** tab
to an app (or open it from the App Launcher) to reach the console.

## 7. Load the demo data

Run the setup scripts in this order (each one is idempotent, so you can run it again):

| # | Script | Creates |
| --- | --- | --- |
| 1 | `scripts/apex/nf_01_seedCatalog.apex` | Residential catalog `NF_RESI`: NFR products, selling models, price book entries, bundles |
| 2 | `scripts/apex/nf_02_seedQualificationRules.apex` | Residential qualification rules (ProductQualification, technology + minimum speed) |
| 3 | `scripts/apex/nf_11_seedBusinessCatalog.apex` | Business catalog `NF_BIZ`: NFB products, bundles and their qualification rules |
| 4 | `scripts/apex/nf_04_configuratorWorkspace.apex` | The shared configurator workspace quote that carts are configured on (never saved to) |
| 5 | `scripts/apex/nf_05_taxSetup.apex` | Tax treatment and policy (order activation needs one on every item) |
| 6 | `scripts/apex/nf_06_billingSetup.apex` | Billing treatment and policy (order activation needs one too) |
| 7 | `scripts/apex/nf_08_seedLocationPrices.apex` | State prices: one `ItemLocationPrice__c` row per product and state (NY, CA, IL, GA, TX, AK) |
| 8 | `scripts/apex/nf_07a_integrationDefs.apex` | DRO integration definitions for the five mock callouts (uses the Revenue Cloud named credential) |
| 9 | `scripts/apex/nf_07_droConfig.apex` | Residential DRO: technical products, decomposition rules, swimlanes, steps, scenarios, workspace |
| 10 | `scripts/apex/nf_12_droBusinessConfig.apex` | Business DRO: six technical products, decomposition rules, six swimlanes (27 steps), workspace |
| 11 | `scripts/apex/nf_14_fieldServiceSetup.apex` | Field Service: work types, operating hours, a territory and install crews per state, background load |
| 12 | `scripts/apex/nf_03_scheduleCleanup.apex` | Schedules the hourly cleanup of abandoned prospect quotes and accounts |

```powershell
./scripts/run-apex.ps1 -File scripts/apex/nf_01_seedCatalog.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_02_seedQualificationRules.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_11_seedBusinessCatalog.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_04_configuratorWorkspace.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_05_taxSetup.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_06_billingSetup.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_08_seedLocationPrices.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_07a_integrationDefs.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_07_droConfig.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_12_droBusinessConfig.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_14_fieldServiceSetup.apex
./scripts/run-apex.ps1 -File scripts/apex/nf_03_scheduleCleanup.apex
```

**Sample data.** [`data/`](data) holds what these scripts load into the decision tables, exported from the demo org, so
you can review it or load it with Data Loader (match `Product.ProductCode` to your product IDs):

| File | Rows | Read by |
| --- | --- | --- |
| `ProductQualification_rules.csv` | 34 | decision table `NF_Serviceability_Qualification`: a plan qualifies when the technology matches and the address is at least `NF_MinDownloadMbps__c` fast |
| `ItemLocationPrice_state_prices.csv` | 324 | `LocationBasedDecisionTable`: the unit price per product, selling model, price book and state |

## 8. Post-deployment steps

1. **Refresh the decision tables** after loading the data (Setup → **Decision Tables** → open → **Refresh**, or):
   ```bash
   sf api request rest /services/data/v66.0/actions/standard/refreshDecisionTable --method POST --target-org RCPOC --body '{"inputs":[{"decisionTableApiName":"Price_Book_Entry_Decision_Table_v2"}]}'
   sf api request rest /services/data/v66.0/actions/standard/refreshDecisionTable --method POST --target-org RCPOC --body '{"inputs":[{"decisionTableApiName":"NF_Serviceability_Qualification"}]}'
   sf api request rest /services/data/v66.0/actions/standard/refreshDecisionTable --method POST --target-org RCPOC --body '{"inputs":[{"decisionTableApiName":"LocationBasedDecisionTable"}]}'
   ```
2. **Product Discovery settings** (Setup → **Revenue Settings** / Product Discovery): browse context
   `NF_NovaDiscoveryCtx`, pricing **on** with procedure *Product Discovery Pricing Procedure*, qualification **on** with
   procedure *NF Serviceability Qualification*. Activate both expression sets if they deployed as drafts.
3. **CML constraint model.** Compile and activate it in the Constraint Builder (only the builder compiles a model):
   ```bash
   cd scripts/cml && npm install && npx playwright install chromium && cd ../..
   python scripts/cml/nf_cml.py scripts/cml/NF_Business_Rules.json
   ```
4. **Location pricing.** In the quote pricing procedure (*Rev_Mgmt_Default_Pricing_Procedure*), make sure the
   **Location Based Price** step looks up `LocationBasedDecisionTable` with the line's `ItemLocationState__c`. Then open the
   **QuoteProcedure** procedure plan and add the Apex class `ApexDmlAttributePreHook` as a pre-hook in the section that
   runs **before** the pricing procedure, so every line gets its site's state before it's priced. Check it with
   `scripts/apex/nf_09_testMultiSitePricing.apex` (a quote in New York and Texas) and
   `nf_10_testSessionLocationPricing.apex` (a configurator session).
5. **Document templates.** Register the Word templates in [`docs/templates`](docs/templates) as Salesforce
   document templates, then activate them:
   ```bash
   python scripts/docgen/setup_templates.py
   ```
   `build_templates.py` regenerates the `.docx` files if you want to change them. The proposal's data comes from
   `NF_ProposalContext`; `scripts/context/nf_proposal_context.py` rebuilds its attributes if you add fields.
6. **DocuSign.** See [Set up DocuSign](#set-up-docusign) below. Until it's done, signing falls back to a
   typed-name sandbox signature, so the rest of the journey works.
7. **Flows** deploy active. The DRO workspaces and plans are created active by the setup scripts.

## 9. Try it

1. Open the **NF Guided Selling** tab and switch to **Multi-site**.
2. Load the sample sites (or upload a CSV with name, street, city, state, ZIP), then **Check sites**.
3. Configure Dedicated Internet 10 Gbps at the New York site: diverse path and DDoS protection are added by the CML rules.
   Use **Apply to all** to copy the cart to the other sites, and compare the state prices.
4. **Review**, **Create quote**, generate the proposal and send it for signature, then place the order and book installers.
5. Open the order: one fulfillment plan with intake and billing once and lanes per site. Complete the manual Tasks
   (or run `scripts/apex/nf_13_completeManualTasks.apex`) and watch every site go live.

## Set up DocuSign

*Proposal signing with Salesforce Contracts.*

The business proposal is signed with the standard **Salesforce Contracts e-signature**, with DocuSign as the provider.
Salesforce emails the proposal to the customer's signatory and tracks the envelope on the contract, so it's configuration
only, with no custom DocuSign code. Until it's configured, the journey falls back to a typed-name sandbox signature.

1. **DocuSign developer account.** Sign up for free at <https://developers.docusign.com>. In **Settings → Apps and Keys**,
   note your **API Account ID**.
2. **App in DocuSign.** Apps and Keys → **Add App and Integration Key**. Note the **Integration Key**, add a **Secret Key**,
   and add the redirect URI `https://<your-domain>.my.salesforce.com/services/authcallback/DocuSignAuthProvider`.
3. **Auth provider in Salesforce.** Setup → **Auth. Providers** → **New** → **Open ID Connect**:

   | Field | Value |
   | --- | --- |
   | Name / URL suffix | `DocuSignAuthProvider` |
   | Consumer Key / Secret | the integration key and the secret key |
   | Authorize Endpoint URL | `https://account-d.docusign.com/oauth/auth` |
   | Token Endpoint URL | `https://account-d.docusign.com/oauth/token` |
   | User Info Endpoint URL | `https://account-d.docusign.com/oauth/userinfo` |
   | Default Scopes | `signature extended` |

4. **Named credential.** Setup → **Named Credentials** → **New Legacy**: name `NF_DocuSign_eSignature`, URL
   `https://demo.docusign.net`, identity type **Named Principal**, protocol **OAuth 2.0**, provider `DocuSignAuthProvider`,
   scope `signature extended`, **Start Authentication Flow on Save** checked. Save, and sign in to DocuSign when asked.
5. **Salesforce Contracts e-signature settings** (stored as `ESignatureConfig` records, vendor DocuSign):

   | Setting | Value |
   | --- | --- |
   | Callout named credential | `NF_DocuSign_eSignature` |
   | Vendor account ID | your API account ID |
   | Anchor string | `signHereTabs:nfSignHere,dateSignedTabs:nfDateSigned` |
   | Signer roles | `Signer 1` |

6. **Signature anchors.** The proposal template carries invisible anchors, `\\nfSignHere1\\` and `\\nfDateSigned1\\` (the
   anchor name plus the signer number), written by `scripts/docgen/build_templates.py`.

After signing, the envelope status syncs back to the contract and the rep can place the order. For a production DocuSign
account, use `account.docusign.com` and your account's own base URI instead.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Offers come back unpriced or `ProductDetailsNotFound` | Run **Sync Pricing Data** and refresh `Price_Book_Entry_Decision_Table_v2` after seeding the catalog |
| Every plan shows, even ones the address can't get | Refresh `NF_Serviceability_Qualification`; check the Product Discovery qualification setting |
| Cart rules don't fire after a model change | Only the Constraint Builder compiles CML: rerun `nf_cml.py` (it deactivates and activates the model) |
| An active expression set won't redeploy | Deactivate its version first (`ExpressionSetVersion.IsActive = false`) |
| Order activation fails | Run `nf_05_taxSetup` and `nf_06_billingSetup`; orders need tax and billing treatments and addresses |
| Deploying Apex fails with "jobs pending" | Run `nf_00_pauseCleanup.apex`, deploy, then `nf_03_scheduleCleanup.apex` |
| Different states get the same price | The pre-hook isn't in the QuoteProcedure plan, or the decision table wasn't refreshed after `nf_08` |
| Callouts fail with "Unauthorized endpoint" | Check the named credential URLs; DocuSign also needs its remote sites |

## Not included on purpose

Org-specific or secret pieces aren't in this repo; create them in your org as described above: the External Client App and
its keys, DocuSign keys, certificate and connection, profiles and org settings.

## What's in this folder

| Path | What it is |
| --- | --- |
| `force-app/` | the Salesforce metadata (deploy with `manifest/package.xml`) |
| `scripts/apex/` | setup scripts, run in the order of step 7 |
| `scripts/cml/` | the CML model spec, generator and Constraint Builder activation |
| `scripts/docgen/` | the Word templates builder and the template / Data Mapper registration |
| `scripts/context/` | rebuilds the proposal context attributes |
| `data/` | sample decision table data exported from the demo org |
| `mocks/` | Postman collections for the two mock systems |
| `docs/templates/` | the Word document templates |

111 metadata components. **Bold** ones are specific to this journey; the rest is the shared NovaFiber core
(the website shell, journey controller, offer, quote, order, document, e-signature, scheduling and fulfillment
services), included so this folder deploys on its own. The folder also carries the residential and agent classes and components, because the shared shell and controller reference them.

- **Apex** (42): **ApexDmlAttributePreHook**, **ApexDmlAttributePreHookTest**, NF_AgentActionBookInstall, NF_AgentActionCheckAddress, NF_AgentActionFindPlans, NF_AgentActionInstallSlots, NF_AgentActionJourneyStatus, NF_AgentActionPlaceOrder, NF_AgentActionSaveQuote, NF_AgentActionShowAddOns, NF_AgentActionUpdateCart, NF_AgentApi, NF_AgentGateway, NF_AgentJourney, NF_ConfigRules, NF_ConfigRulesTest, **NF_DocumentService**, NF_DocumentTest, NF_DroCalloutProvider, NF_DroService, NF_ESignService, NF_FulfillmentCallbackApi, NF_FulfillmentSimulator, NF_FulfillmentStatus, NF_FulfillmentTest, NF_JourneyCache, NF_JourneyCleanup, NF_JourneyController, NF_JourneyModels, NF_JourneyTest, NF_JourneyWorker, **NF_MultiSiteService**, NF_OfferService, NF_OrderService, NF_PortalController, NF_PortalService, NF_QuoteService, NF_RevCloudApi, NF_SchedulingService, NF_SchedulingTest, NF_ServiceabilityService, NF_Trace
- **Lightning Web Components** (23): nfAddOns, nfAddressForm, nfAgentJourney, nfAgentPanel, nfAgreement, nfApi, nfCart, nfCheckoutForm, nfGuidedSelling, nfIllustration, nfInspector, nfInstallBooking, nfLanding, **nfMultiSite**, nfOfferCard, nfOfferConfigurator, nfOrderConfirmation, nfPortal, nfProgress, nfQuoteReview, nfServiceabilityBanner, nfStyles, nfUtils
- **Objects and fields** (17): Account, Contract, **ItemLocationPrice__c**, NF_Agent_Journey__c, NF_DocuSign_Settings__c, NF_Fulfillment_Event__c, NF_Journey_Request__c, NF_Journey_Setting__mdt, NF_Journey_Signal__e, NF_Portal_Session__c, NF_Portal_User__c, Order, Product2, ProductQualification, Quote, QuoteLineItem, WorkOrder
- **Flows** (9): NF_Create_Order_From_Quote, NF_DRO_Milestone_Active, NF_DRO_Milestone_Installation_Complete, NF_DRO_Milestone_Installation_Scheduled, NF_DRO_Milestone_Network_Reserved, NF_DRO_Milestone_Order_Confirmed, NF_DRO_Milestone_Service_Active, NF_DRO_Validate_Order, NF_Quote_Line_Document_Fields
- **Expression sets (CML models, qualification, discovery pricing)** (3): **NF_Business_Rules**, NF_Serviceability_Qualification, Product_Discovery_Pricing_Procedure
- **Decision tables** (1): NF_Serviceability_Qualification
- **Context definitions** (2): NF_NovaDiscoveryCtx, **NF_ProposalContext**
- **Permission sets** (2): NF_Fulfillment_Ops, NF_Guided_Selling
- **Custom permissions** (1): NF_Agent_Assisted_Selling
- **Named credentials** (4): NF_AgentApi, NF_FulfillmentSystems, NF_RevenueCloud, NF_Serviceability
- **External credentials** (1): NF_RevenueCloud_API
- **Custom metadata records** (1): NF_Journey_Setting
- **Platform Cache partitions** (1): NFJourney
- **Triggers** (1): NF_JourneyRequestTrigger
- **Tabs** (1): NF_Guided_Selling
- **Static resources** (1): NF_ESignReturn
- **Platform event subscriber configs** (1): NF_JourneyWorkerConfig

---
Built by Stratus Carta as a proof of concept on Salesforce Revenue Cloud (API v66.0). Provided as is, for learning and demos.
