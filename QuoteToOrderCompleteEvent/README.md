# Quote to Order Complete Event

Salesforce example that reacts to the **`QuoteToOrderCompletedEvent`** platform event: when a Quote finishes converting to Order(s), it locks the Quote and notifies the Quote Owner once.

## What's included

| Component | Purpose |
|---|---|
| Flow `Lock_Quote_On_Order_Completion` | Platform event–triggered flow. Checks the `AsyncOperationTracker` records, and when the parent tracker is Completed, locks the Quote and notifies the owner (custom notification + email). |
| Apex `LockRecordOnce` (+ test) | Invocable action that locks each record only once per bulk call. Avoids the "already in queue to be locked" error and duplicate notifications when several Orders of the same Quote complete together. |
| Custom Notification Type `QuoteConvertedToOrder` | Bell notification sent to the Quote Owner. |
| Object `QuoteToOrderInspect__c` (+ tab, layout, permission set) | Optional monitoring: one record per event with the Quote/Order and tracker statuses at the moment the flow ran. |
| `Apex.settings` | Org Apex settings used by the example. |

## Deploy

With the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli):

```bash
sf org login web --alias myorg
sf project deploy start --manifest manifest/package.xml --target-org myorg --test-level RunSpecifiedTests --tests LockRecordOnceTest
sf org assign permset --name QuoteToOrderInspect --target-org myorg
```

Then activate the flow **Lock Quote On Order Completion** in Setup if it isn't active.
