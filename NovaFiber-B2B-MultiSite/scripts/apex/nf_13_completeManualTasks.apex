// Demo / ops helper: completes the open DRO manual-step Tasks of one order (credit review, site survey,
// circuit turn-up, engineer installation, service configuration...). Completing a Task completes its
// ManualTask step, and the plan moves on. Run it again as new manual steps open.
// Set the order number below.
String orderNumber = '00000266';

Order o = [SELECT Id, OrderNumber FROM Order WHERE OrderNumber = :orderNumber LIMIT 1];
List<Task> open = [SELECT Id, Subject FROM Task WHERE WhatId = :o.Id AND IsClosed = false];
for (Task t : open) t.Status = 'Completed';
update open;

List<String> done = new List<String>();
for (Task t : open) done.add(t.Subject);
System.debug('Order ' + o.OrderNumber + ': completed ' + open.size() + ' task(s) ' + String.join(done, ', '));
