// Removes only the sample data, so the simulation can be run from a clean state.
// Run as the deploying admin with Orders_CX_User assigned.
// Deleting the Account also deletes its External Orders (master-detail).
delete [SELECT Id FROM Order_Event__c WHERE Orders_Order_Id__c IN ('ord_77d1e9', 'ord_52ab10') OR Event_Id__c LIKE 'invalid:%' OR Event_Id__c LIKE 'evt_tampered%'];
delete [SELECT Id FROM Account WHERE Orders_Account_Id__c = 'acct_8f3c2a'];
delete [SELECT Id FROM Integration_Error__c WHERE Event_Id__c LIKE 'evt_%' OR Event_Id__c LIKE 'invalid:%'];
