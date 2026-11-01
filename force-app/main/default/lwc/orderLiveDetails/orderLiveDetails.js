import { LightningElement, api } from "lwc";
import getLiveDetails from "@salesforce/apex/OrderDetailsController.getLiveDetails";

const COLUMNS = [
  { label: "Line", fieldName: "id" },
  { label: "Type", fieldName: "type" },
  { label: "Status", fieldName: "status" },
  { label: "Amount", fieldName: "amountText" }
];

/**
 * Reads amount, lines and participant from Orders each time the page opens.
 * Imperative and uncached on purpose: these values are never stored, and a stale
 * copy in the browser would defeat the point of reading them live.
 */
export default class OrderLiveDetails extends LightningElement {
  @api recordId;

  columns = COLUMNS;
  details;
  error;
  isLoading = false;

  connectedCallback() {
    this.load();
  }

  async load() {
    this.isLoading = true;
    this.error = undefined;
    try {
      this.details = await getLiveDetails({ externalOrderId: this.recordId });
    } catch (e) {
      this.details = undefined;
      this.error = e?.body?.message ?? "Could not load details from Orders.";
    } finally {
      this.isLoading = false;
    }
  }

  get amountText() {
    return formatMoney(this.details?.amount);
  }

  get lines() {
    return (this.details?.lines ?? []).map((line) => ({
      ...line,
      amountText: formatMoney(line.amount)
    }));
  }
}

function formatMoney(money) {
  return money?.value ? `${money.value} ${money.currencyCode}` : "";
}
