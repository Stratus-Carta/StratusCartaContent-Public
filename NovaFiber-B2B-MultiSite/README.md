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

**How a site's state reaches the price:** `ItemLocationPrice__c` rows feed the standard Location Based Decision Table; the
standard Location Based Price step reads `ItemLocationState__c`, a custom attribute on the sales transaction line, which the
`ApexDmlAttributePreHook` (a `RevSignaling.SignalingApexProcessor` in the `QuoteProcedure` procedure plan) fills from the
line's site before pricing. Add `ItemLocationState__c` to your sales transaction context extension and put the hook in
section 1 of the procedure plan, before the default pricing procedure.

Watch the demo: *NovaFiber Multi-Site Demo, Behind the Scenes* (Stratus Carta).

## What you need

- A Salesforce org with **Revenue Cloud** (Product Catalog, Pricing, Configurator, Transaction Management, Salesforce Contracts,
  Dynamic Revenue Orchestrator) and **Field Service**. A Revenue Cloud developer org or the Communications Cloud trial works.
- Salesforce CLI (`sf`) v2, Python 3 and Node 18+ for the setup scripts.
- Two HTTP mocks (Postman, Mockoon, or any small service) standing in for the outside systems:
  - **Network inventory**: `POST /nf/serviceability?postalCode=…` returns the access technology and top download speed for an
    address (see `NF_ServiceabilityService` for the fields it reads).
  - **Fulfillment systems**: `POST /provisioning/v1/reservations`, `/provisioning/v1/activations`, `/logistics/v1/shipments`,
    `/billing/v1/accounts`, `/billing/v1/subscriptions`. A `200` completes the DRO step at once; a `202` keeps it in progress
    until the system posts to `/services/apexrest/nf/fulfillment/v1/callback` (see `NF_DroCalloutProvider`). In this demo,
    `NF_FulfillmentSimulator` plays the callbacks.


## Replace the placeholders before you deploy

| File | Placeholder | Put in |
| --- | --- | --- |
| `namedCredentials/NF_RevenueCloud.namedCredential-meta.xml` | `YOUR-MY-DOMAIN` | your org's My Domain |
| `externalCredentials/NF_RevenueCloud_API.externalCredential-meta.xml` | `YOUR-MY-DOMAIN` | your org's My Domain (token URL) |
| `namedCredentials/NF_Serviceability.namedCredential-meta.xml` | `YOUR-SERVICEABILITY-MOCK.example.com` | your network inventory mock |
| `namedCredentials/NF_FulfillmentSystems.namedCredential-meta.xml` | `YOUR-FULFILLMENT-MOCK.example.com` | your fulfillment mock |
| `platformEventSubscriberConfigs/NF_JourneyWorkerConfig…` | `YOUR-INTEGRATION-USERNAME@your-org.example` | the user the journey worker runs as |

The Revenue Cloud named credential calls the org's own Connect REST APIs with the client credentials flow: create an External
Client App with client credentials enabled, set its run-as user, and add its consumer key and secret to the
`NF_RevenueCloud_API` external credential principal in Setup. Keys and secrets are never stored in this repo.


## Deploy

```bash
sf org login web --alias RCPOC --instance-url https://<mydomain>.my.salesforce.com
sf project deploy start --manifest manifest/package.xml --target-org RCPOC
```

The setup scripts use the org alias `RCPOC` (change `ORG` at the top of the Python scripts, or set `NF_ORG`, to use another).
Flows, expression sets and decision tables may deploy inactive; activate them in Setup after the data is in.

## Set up the data, in order

```powershell
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_00_pauseCleanup.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_01_seedCatalog.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_02_seedQualificationRules.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_04_configuratorWorkspace.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_05_taxSetup.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_06_billingSetup.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_07a_integrationDefs.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_07_droConfig.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_11_seedBusinessCatalog.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_08_seedLocationPrices.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_12_droBusinessConfig.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_14_fieldServiceSetup.apex
./scripts/run-apex.ps1 -Org RCPOC -File scripts/apex/nf_03_scheduleCleanup.apex
```

Then deploy and activate the CML constraint model with `python scripts/cml/nf_cml.py` (it compiles the model in the Constraint
Builder and activates it), and build the document templates with `python scripts/docgen/build_templates.py` followed by
`python scripts/docgen/setup_templates.py`.
After `nf_08_seedLocationPrices.apex`, refresh the table: `POST /services/data/v66.0/actions/standard/refreshDecisionTable` with `{"decisionTableApiName":"LocationBasedDecisionTable"}`.
Check location pricing with `nf_09_testMultiSitePricing.apex` (a quote in New York and Texas) and `nf_10_testSessionLocationPricing.apex` (a configurator session).


## Not included

Org-specific or secret pieces are left out on purpose; create them in your org:

- **DocuSign**: the JWT certificate, auth provider and integration key (the business proposal uses the standard Salesforce Contracts e-signature with DocuSign as the provider).
- **External Client App** and its OAuth settings for the Revenue Cloud named credential.
- **Experience Cloud site**, profiles and org settings (the rep uses `nfGuidedSelling` on a Lightning page in multi-site mode).
- Sample data beyond what the setup scripts create.


## What's in this folder

110 components. **Bold** ones are specific to this journey; the rest is the shared NovaFiber core (the
website shell, journey controller, offer, quote, order, document, e-signature, scheduling and fulfillment services),
included so this folder deploys on its own.

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
- **Static resources** (1): NF_ESignReturn
- **Platform event subscriber configs** (1): NF_JourneyWorkerConfig

---
Built by Stratus Carta as a proof of concept on Revenue Cloud (API v66.0). Provided as is, for learning and demos.
