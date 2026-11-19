import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type CustomerOption = { id: string; display_name: string; business_name?: string | null };
type OrderRow = { id: string; order_number: string; customer_id: string };
type InvoiceRow = {
  id: string;
  invoice_number: string;
  status: string;
  total_amount: number;
  issue_date: string;
  due_date: string | null;
  order_id: string;
  customer_id: string;
  customer_name: string;
  order_number: string;
};
type InvoiceItem = {
  id: string;
  invoice_id: string;
  description: string;
  quantity: number;
  unit_price: number;
  line_total: number;
};
type CreditNote = {
  id: string;
  credit_note_number: string;
  status: string;
  reason: string;
  total_amount: number;
  issued_at: string | null;
  invoice_id: string;
  customer_id: string;
  created_at: string;
  invoice_number: string;
  customer_name: string;
};
type PaymentAllocation = { invoice_id: string; payment_id: string; amount: number };
type PaymentStatus = { id: string; status: string };
type CreditEntry = { customer_id: string; invoice_id: string | null; entry_type: string; amount: number };
type LineDraft = {
  invoice_item_id: string;
  description: string;
  quantity: string;
  unit_price: string;
  amount: string;
};

const requestId = () => crypto.randomUUID();
const money = (n: number) => new Intl.NumberFormat("en-KE", { style: "currency", currency: "KES", maximumFractionDigits: 0 }).format(n);
const blankLine = (): LineDraft => ({ invoice_item_id: "", description: "", quantity: "1", unit_price: "", amount: "" });

export default function CreditNoteWorkflow({
  businessId,
  customers,
  onChanged,
}: {
  businessId: string;
  customers: CustomerOption[];
  onChanged: () => void;
}) {
  const [invoices, setInvoices] = useState<InvoiceRow[]>([]);
  const [invoiceItems, setInvoiceItems] = useState<InvoiceItem[]>([]);
  const [creditNotes, setCreditNotes] = useState<CreditNote[]>([]);
  const [allocations, setAllocations] = useState<PaymentAllocation[]>([]);
  const [payments, setPayments] = useState<PaymentStatus[]>([]);
  const [creditEntries, setCreditEntries] = useState<CreditEntry[]>([]);
  const [invoiceId, setInvoiceId] = useState("");
  const [reason, setReason] = useState("");
  const [lines, setLines] = useState<LineDraft[]>([blankLine()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    if (!supabase) return;
    const [invoiceResult, orderResult, itemResult, noteResult, allocationResult, paymentResult, creditResult] = await Promise.all([
      supabase.from("sales_invoices").select("id,invoice_number,status,total_amount,issue_date,due_date,order_id").eq("business_id", businessId).order("issue_date", { ascending: false }).limit(500),
      supabase.from("orders").select("id,order_number,customer_id").eq("business_id", businessId).limit(1000),
      supabase.from("sales_invoice_items").select("id,invoice_id,description,quantity,unit_price,line_total").eq("business_id", businessId).limit(2000),
      supabase.from("sales_credit_notes").select("id,credit_note_number,status,reason,total_amount,issued_at,invoice_id,customer_id,created_at").eq("business_id", businessId).order("created_at", { ascending: false }).limit(500),
      supabase.from("sales_invoice_payment_allocations").select("invoice_id,payment_id,amount").eq("business_id", businessId).limit(2000),
      supabase.from("payments").select("id,status").eq("business_id", businessId).limit(2000),
      supabase.from("sales_customer_credit_entries").select("customer_id,invoice_id,entry_type,amount").eq("business_id", businessId).limit(4000),
    ]);
    const failed = [invoiceResult, orderResult, itemResult, noteResult, allocationResult, paymentResult, creditResult].find(result => result.error);
    if (failed?.error) throw failed.error;

    const customerMap = new Map(customers.map(customer => [customer.id, customer]));
    const orderRows = (orderResult.data ?? []) as OrderRow[];
    const orderMap = new Map(orderRows.map(order => [order.id, order]));
    const invoiceRows = ((invoiceResult.data ?? []) as Omit<InvoiceRow, "customer_id" | "customer_name" | "order_number">[]).flatMap(invoice => {
      const order = orderMap.get(invoice.order_id);
      const customer = order ? customerMap.get(order.customer_id) : undefined;
      return order && customer ? [{
        ...invoice,
        customer_id: order.customer_id,
        customer_name: customer.business_name || customer.display_name,
        order_number: order.order_number,
      }] : [];
    });
    const invoiceMap = new Map(invoiceRows.map(invoice => [invoice.id, invoice]));
    setInvoices(invoiceRows);
    setInvoiceItems((itemResult.data ?? []) as InvoiceItem[]);
    setCreditNotes(((noteResult.data ?? []) as Omit<CreditNote, "invoice_number" | "customer_name">[]).map(note => {
      const invoice = invoiceMap.get(note.invoice_id);
      const customer = customerMap.get(note.customer_id);
      return {
        ...note,
        invoice_number: invoice?.invoice_number ?? "Invoice unavailable",
        customer_name: customer?.business_name || customer?.display_name || "Customer unavailable",
      };
    }));
    setAllocations((allocationResult.data ?? []) as PaymentAllocation[]);
    setPayments((paymentResult.data ?? []) as PaymentStatus[]);
    setCreditEntries((creditResult.data ?? []) as CreditEntry[]);
  }, [businessId, customers]);

  useEffect(() => {
    void load().catch(e => setError(e instanceof Error ? e.message : "Could not load credit notes."));
  }, [load]);

  const selectedInvoice = useMemo(() => invoices.find(invoice => invoice.id === invoiceId) ?? null, [invoices, invoiceId]);
  const selectedItems = useMemo(() => invoiceItems.filter(item => item.invoice_id === invoiceId), [invoiceItems, invoiceId]);
  const paymentMap = useMemo(() => new Map(payments.map(payment => [payment.id, payment.status])), [payments]);

  const invoiceBalance = (invoice: InvoiceRow) => {
    const paid = allocations
      .filter(allocation => allocation.invoice_id === invoice.id && paymentMap.get(allocation.payment_id) === "posted")
      .reduce((sum, allocation) => sum + Number(allocation.amount), 0);
    const appliedCredit = creditEntries
      .filter(entry => entry.invoice_id === invoice.id && entry.entry_type === "apply_to_invoice")
      .reduce((sum, entry) => sum - Number(entry.amount), 0);
    return Math.max(Number(invoice.total_amount) - paid - appliedCredit, 0);
  };

  const eligibleInvoices = invoices.filter(invoice => ["sent", "partially_paid", "paid", "overdue"].includes(invoice.status));
  const lineTotal = lines.reduce((sum, line) => sum + (Number(line.amount) || 0), 0);
  const updateLine = (index: number, patch: Partial<LineDraft>) => {
    setLines(current => current.map((line, i) => i === index ? { ...line, ...patch } : line));
  };

  function selectInvoice(nextId: string) {
    setInvoiceId(nextId);
    setLines([blankLine()]);
    setReason("");
    setError("");
    setNotice("");
  }

  function selectInvoiceItem(index: number, itemId: string) {
    const item = selectedItems.find(candidate => candidate.id === itemId);
    if (!item) {
      updateLine(index, { invoice_item_id: "", description: "", quantity: "1", unit_price: "", amount: "" });
      return;
    }
    updateLine(index, {
      invoice_item_id: item.id,
      description: item.description,
      quantity: String(item.quantity),
      unit_price: String(item.unit_price),
      amount: String(item.line_total),
    });
  }

  async function issueCreditNote(event: FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    if (!invoiceId || !reason.trim()) {
      setError("Choose an invoice and enter the reason for the credit note.");
      return;
    }
    const payload = lines.map(line => ({
      invoice_item_id: line.invoice_item_id || null,
      description: line.description.trim(),
      quantity: Number(line.quantity),
      unit_price: Number(line.unit_price),
      amount: Number(line.amount),
    }));
    const invalid = payload.some(line =>
      !line.description
      || !Number.isFinite(line.quantity) || line.quantity <= 0
      || !Number.isSafeInteger(line.unit_price) || line.unit_price < 0
      || !Number.isSafeInteger(line.amount) || line.amount < 0
      || line.amount > Math.round(line.quantity * line.unit_price)
    );
    if (invalid || payload.reduce((sum, line) => sum + line.amount, 0) <= 0) {
      setError("Complete each line with a description, positive quantity, whole-KES unit price and amount. The amount cannot exceed quantity × unit price.");
      return;
    }

    setBusy(true);
    setError("");
    setNotice("");
    const { data, error: rpcError } = await supabase.rpc("owner_issue_sales_credit_note", {
      p_business_id: businessId,
      p_invoice_id: invoiceId,
      p_reason: reason.trim(),
      p_items: payload,
      p_discount_amount: 0,
      p_request_id: requestId(),
    });
    if (rpcError) {
      setError(rpcError.message);
    } else {
      const applied = Number(data?.amount_applied_to_invoice ?? 0);
      const remainingCredit = Number(data?.total_amount ?? 0) - applied;
      setNotice(
        "Credit note " + data.credit_note_number + " issued for " + money(Number(data.total_amount)) + ". "
        + (applied > 0 ? money(applied) + " applied to the invoice. " : "")
        + (remainingCredit > 0 ? money(remainingCredit) + " added to customer credit." : "No excess customer credit created.")
      );
      setInvoiceId("");
      setReason("");
      setLines([blankLine()]);
      await load();
      onChanged();
    }
    setBusy(false);
  }

  return <div className="credit-note-workflow">
    <section className="connected-panel">
      <div className="panel-toolbar">
        <div><h2>Issue a credit note</h2><p>Adjust an issued invoice without reversing its original payment.</p></div>
        <button type="button" className="secondary-action" onClick={() => void load()} disabled={busy}>↻ Refresh</button>
      </div>
      {error && <div className="notice error" role="alert">{error}</div>}
      {notice && <div className="notice success" role="status">{notice}</div>}
      <form onSubmit={issueCreditNote}>
        <div className="form-grid">
          <label>Invoice
            <select required value={invoiceId} onChange={event => selectInvoice(event.target.value)}>
              <option value="">Select an issued invoice</option>
              {eligibleInvoices.map(invoice => <option key={invoice.id} value={invoice.id}>
                {invoice.invoice_number} · {invoice.customer_name} · {invoice.status} · Balance {money(invoiceBalance(invoice))}
              </option>)}
            </select>
          </label>
          <label>Reason for credit note
            <input required maxLength={1000} value={reason} onChange={event => setReason(event.target.value)} placeholder="e.g. Returned items, incorrect quantity or agreed price adjustment" />
          </label>
        </div>

        {selectedInvoice && <div className="credit-note-context">
          <b>{selectedInvoice.invoice_number} · {selectedInvoice.customer_name}</b>
          <span>Original invoice {money(Number(selectedInvoice.total_amount))} · Outstanding {money(invoiceBalance(selectedInvoice))}</span>
          <p>{invoiceBalance(selectedInvoice) === 0
            ? "This invoice is fully paid. The credit note value will become customer credit; the original receipt remains unchanged."
            : "The system applies the credit note to the outstanding invoice balance first. Any excess becomes customer credit."}</p>
        </div>}

        {selectedInvoice && <div className="credit-note-lines">
          <div className="panel-toolbar"><div><h3>Credit note lines</h3><p>Link a line to the original invoice item where possible.</p></div></div>
          {lines.map((line, index) => <div className="credit-note-line" key={index}>
            <label>Original invoice item
              <select value={line.invoice_item_id} onChange={event => selectInvoiceItem(index, event.target.value)}>
                <option value="">General adjustment / not linked to an item</option>
                {selectedItems.map(item => <option key={item.id} value={item.id}>{item.description} · {money(Number(item.line_total))}</option>)}
              </select>
            </label>
            <label>Description
              <input required value={line.description} onChange={event => updateLine(index, { description: event.target.value })} placeholder="Credit note line description" />
            </label>
            <div className="credit-note-line-fields">
              <label>Quantity
                <input required type="number" min="0.001" step="0.001" value={line.quantity} onChange={event => updateLine(index, { quantity: event.target.value })} />
              </label>
              <label>Unit price (KES)
                <input required type="number" min="0" step="1" value={line.unit_price} onChange={event => updateLine(index, { unit_price: event.target.value })} />
              </label>
              <label>Credit amount (KES)
                <input required type="number" min="0" step="1" value={line.amount} onChange={event => updateLine(index, { amount: event.target.value })} />
              </label>
            </div>
            {lines.length > 1 && <button type="button" className="text-action" onClick={() => setLines(current => current.filter((_, i) => i !== index))}>Remove line</button>}
          </div>)}
          <div className="credit-note-line-actions">
            <button type="button" className="secondary-action" onClick={() => setLines(current => [...current, blankLine()])}>＋ Add line</button>
            <strong>Credit note total: {money(lineTotal)}</strong>
          </div>
        </div>}

        <div className="credit-note-submit">
          <p>Issuing a credit note is an audited invoice adjustment. It does not reverse a payment or create a cash refund.</p>
          <button className="primary-action" disabled={busy || !selectedInvoice || !reason.trim() || lineTotal <= 0}>
            {busy ? "Issuing credit note…" : "Issue credit note"}
          </button>
        </div>
      </form>
    </section>

    <section className="connected-panel">
      <div className="panel-toolbar"><div><h2>Credit note history</h2><p>Issued adjustments and their original invoices.</p></div><span className="count-chip">{creditNotes.length} records</span></div>
      <div className="record-list">
        {creditNotes.map(note => <article className="enquiry-card" key={note.id}>
          <div className="enquiry-top">
            <div><b>{note.credit_note_number}</b><small>{note.invoice_number} · {note.customer_name}</small></div>
            <span className={"status-chip " + note.status}>{note.status}</span>
          </div>
          <p>{note.reason}</p>
          <strong>{money(Number(note.total_amount))}</strong>
          <small>{note.issued_at ? "Issued " + new Date(note.issued_at).toLocaleString("en-KE") : "Created " + new Date(note.created_at).toLocaleString("en-KE")}</small>
        </article>)}
        {!creditNotes.length && <p className="empty-records">No credit notes have been issued.</p>}
      </div>
    </section>
  </div>;
}
