import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type CustomerOption = { id: string; display_name: string };
type OrderRow = { id: string; order_number: string; customer_id: string };
type Invoice = { id: string; invoice_number: string; status: string; total_amount: number; due_date: string | null; order_id: string; customer_id: string; order_number: string };
type AccountType = "cash" | "mpesa_paybill" | "bank" | "cheque_clearing";
type Method = "cash" | "mpesa_manual" | "bank_transfer" | "cheque";
type Account = { id: string; account_name: string; account_type: AccountType; account_reference: string | null; bank_name: string | null; is_active: boolean };
type Payment = { id: string; payment_number: string; method: Method; status: string; amount: number; received_at: string; mpesa_reference: string | null; external_reference: string | null; receiving_account_id: string | null; notes: string | null; duplicate_reference_warning: boolean };
type Receipt = { id: string; receipt_number: string; payment_id: string; customer_name_snapshot: string; amount: number; issued_at: string };
type InvoiceAllocation = { payment_id: string; invoice_id: string; amount: number };
type LegacyAllocation = { id: string; payment_id: string; order_id: string; amount: number };
type Refund = { id: string; payment_id: string; order_id: string | null; allocation_id: string | null; source_bucket: string; amount: number; status: string; reason: string; refund_method: string; external_reference: string | null; created_at: string };
type Reconciliation = { payment_id: string; reconciliation_date: string; statement_reference: string | null; notes: string | null };
type CreditEntry = { customer_id: string; amount: number; invoice_id: string | null; entry_type: string };
type AllocationDraft = { invoice_id: string; amount: string };

const requestId = () => crypto.randomUUID();
const money = (n: number) => new Intl.NumberFormat("en-KE", { style: "currency", currency: "KES", maximumFractionDigits: 0 }).format(n);
const localDateTime = () => {
  const date = new Date();
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
};
const accountTypeForMethod: Record<Method, AccountType[]> = {
  cash: ["cash"],
  mpesa_manual: ["mpesa_paybill"],
  bank_transfer: ["bank"],
  cheque: ["bank", "cheque_clearing"],
};
const methodLabel: Record<Method, string> = {
  cash: "Cash",
  mpesa_manual: "M-Pesa Paybill",
  bank_transfer: "Bank transfer",
  cheque: "Cheque",
};

export default function PaymentWorkflow({ businessId, customers, onChanged }: { businessId: string; customers: CustomerOption[]; onChanged: () => void }) {
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [legacyAllocations, setLegacyAllocations] = useState<LegacyAllocation[]>([]);
  const [refunds, setRefunds] = useState<Refund[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [receipts, setReceipts] = useState<Receipt[]>([]);
  const [allocations, setAllocations] = useState<InvoiceAllocation[]>([]);
  const [reconciliations, setReconciliations] = useState<Reconciliation[]>([]);
  const [creditEntries, setCreditEntries] = useState<CreditEntry[]>([]);
  const [creditCustomerId, setCreditCustomerId] = useState("");
  const [creditInvoiceId, setCreditInvoiceId] = useState("");
  const [creditAmount, setCreditAmount] = useState("");
  const [refundPayment, setRefundPayment] = useState("");
  const [refundAllocation, setRefundAllocation] = useState("");
  const [refundBucket, setRefundBucket] = useState<"allocated" | "unallocated">("allocated");
  const [refundAmount, setRefundAmount] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [refundMethod, setRefundMethod] = useState<"cash" | "mpesa">("mpesa");
  const [refundReference, setRefundReference] = useState("");
  const [customerId, setCustomerId] = useState("");
  const [method, setMethod] = useState<Method>("cash");
  const [accountId, setAccountId] = useState("");
  const [amount, setAmount] = useState("");
  const [receivedAt, setReceivedAt] = useState(localDateTime);
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [allocationDrafts, setAllocationDrafts] = useState<AllocationDraft[]>([]);
  const [accountName, setAccountName] = useState("");
  const [accountType, setAccountType] = useState<AccountType>("cash");
  const [accountReference, setAccountReference] = useState("");
  const [bankName, setBankName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [receipt, setReceipt] = useState<Receipt | null>(null);

  const load = useCallback(async () => {
    if (!supabase) return;
    const [orderResult, invoiceResult, accountResult, paymentResult, receiptResult, allocationResult, reconciliationResult, creditResult, legacyAllocationResult, refundResult] = await Promise.all([
      supabase.from("orders").select("id,order_number,customer_id").eq("business_id", businessId).limit(1000),
      supabase.from("sales_invoices").select("id,invoice_number,status,total_amount,due_date,order_id").eq("business_id", businessId).order("issue_date", { ascending: false }).limit(500),
      supabase.from("sales_payment_accounts").select("id,account_name,account_type,account_reference,bank_name,is_active").eq("business_id", businessId).order("account_name"),
      supabase.from("payments").select("id,payment_number,method,status,amount,received_at,mpesa_reference,external_reference,receiving_account_id,notes,duplicate_reference_warning").eq("business_id", businessId).order("received_at", { ascending: false }).limit(500),
      supabase.from("receipts").select("id,receipt_number,payment_id,customer_name_snapshot,amount,issued_at").eq("business_id", businessId).order("issued_at", { ascending: false }).limit(500),
      supabase.from("sales_invoice_payment_allocations").select("payment_id,invoice_id,amount").eq("business_id", businessId).limit(1000),
      supabase.from("sales_payment_reconciliations").select("payment_id,reconciliation_date,statement_reference,notes").eq("business_id", businessId).limit(1000),
      supabase.from("sales_customer_credit_entries").select("customer_id,amount,invoice_id,entry_type").eq("business_id", businessId).limit(2000),
      supabase.from("payment_allocations").select("id,payment_id,order_id,amount").eq("business_id", businessId).limit(1000),
      supabase.from("payment_refunds").select("id,payment_id,order_id,allocation_id,source_bucket,amount,status,reason,refund_method,external_reference,created_at").eq("business_id", businessId).order("created_at", { ascending: false }).limit(500),
    ]);
    const failed = [orderResult, invoiceResult, accountResult, paymentResult, receiptResult, allocationResult, reconciliationResult, creditResult, legacyAllocationResult, refundResult].find(result => result.error);
    if (failed?.error) throw failed.error;
    const orderRows = (orderResult.data ?? []) as OrderRow[];
    const orderMap = new Map(orderRows.map(order => [order.id, order]));
    setOrders(orderRows);
    const invoiceRows = ((invoiceResult.data ?? []) as Omit<Invoice, "customer_id" | "order_number">[]).flatMap(invoice => {
      const order = orderMap.get(invoice.order_id);
      return order ? [{ ...invoice, customer_id: order.customer_id, order_number: order.order_number }] : [];
    });
    setInvoices(invoiceRows);
    setAccounts((accountResult.data ?? []) as Account[]);
    setPayments((paymentResult.data ?? []) as Payment[]);
    setReceipts((receiptResult.data ?? []) as Receipt[]);
    setAllocations((allocationResult.data ?? []) as InvoiceAllocation[]);
    setReconciliations((reconciliationResult.data ?? []) as Reconciliation[]);
    setCreditEntries((creditResult.data ?? []) as CreditEntry[]);
    setLegacyAllocations((legacyAllocationResult.data ?? []) as LegacyAllocation[]);
    setRefunds((refundResult.data ?? []) as Refund[]);
  }, [businessId]);

  useEffect(() => { void load().catch(e => setError(e instanceof Error ? e.message : "Could not load payments.")); }, [load]);

  const validAccounts = useMemo(() => accounts.filter(account => account.is_active && accountTypeForMethod[method].includes(account.account_type)), [accounts, method]);
  useEffect(() => {
    if (!validAccounts.some(account => account.id === accountId)) setAccountId(validAccounts[0]?.id ?? "");
  }, [validAccounts, accountId]);

  const invoiceBalance = (invoice: Invoice) => {
    const paid = allocations.filter(allocation => allocation.invoice_id === invoice.id && payments.some(payment => payment.id === allocation.payment_id && payment.status === "posted")).reduce((sum, allocation) => sum + Number(allocation.amount), 0);
    const creditApplied = creditEntries.filter(entry => entry.invoice_id === invoice.id && entry.entry_type === "apply_to_invoice").reduce((sum, entry) => sum - Number(entry.amount), 0);
    return Math.max(Number(invoice.total_amount) - paid - creditApplied, 0);
  };
  const customerInvoices = invoices.filter(invoice => invoice.customer_id === customerId && ["sent", "partially_paid", "overdue"].includes(invoice.status) && invoiceBalance(invoice) > 0);
  const allocationTotal = allocationDrafts.reduce((sum, item) => sum + (Number(item.amount) || 0), 0);
  const customerCredit = (id: string) => creditEntries.filter(entry => entry.customer_id === id).reduce((sum, entry) => sum + Number(entry.amount), 0);
  const reconciliationFor = (paymentId: string) => reconciliations.find(item => item.payment_id === paymentId);
  const accountTotals = accounts.map(account => {
    const accountPayments = payments.filter(payment => payment.receiving_account_id === account.id && payment.status === "posted");
    const reconciledIds = new Set(reconciliations.map(item => item.payment_id));
    return {
      ...account,
      total: accountPayments.reduce((sum, payment) => sum + Number(payment.amount), 0),
      reconciled: accountPayments.filter(payment => reconciledIds.has(payment.id)).reduce((sum, payment) => sum + Number(payment.amount), 0),
      unreconciled: accountPayments.filter(payment => !reconciledIds.has(payment.id)).reduce((sum, payment) => sum + Number(payment.amount), 0),
      count: accountPayments.length,
    };
  });

  async function createAccount(event: FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    setBusy(true); setError(""); setNotice("");
    const { error: rpcError } = await supabase.rpc("owner_upsert_sales_payment_account", {
      p_business_id: businessId, p_account_id: null, p_account_name: accountName.trim(),
      p_account_type: accountType, p_account_reference: accountReference.trim() || null,
      p_bank_name: accountType === "bank" ? bankName.trim() || null : null,
      p_is_active: true, p_request_id: requestId(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      setNotice("Receiving account saved.");
      setAccountName(""); setAccountReference(""); setBankName("");
      await load(); onChanged();
    }
    setBusy(false);
  }

  async function recordPayment(event: FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    const amountValue = Number(amount);
    if (!customerId || !accountId || !Number.isSafeInteger(amountValue) || amountValue <= 0) {
      setError("Choose a customer and receiving account, then enter a positive whole-KES amount."); return;
    }
    if (method !== "cash" && !reference.trim()) { setError("Enter the transaction or cheque reference."); return; }
    if (allocationDrafts.some(item => !item.invoice_id || !Number.isSafeInteger(Number(item.amount)) || Number(item.amount) <= 0)) {
      setError("Complete or remove each invoice allocation row."); return;
    }
    if (allocationTotal > amountValue) { setError("Invoice allocations cannot exceed the payment amount."); return; }
    setBusy(true); setError(""); setNotice("");
    const { data, error: rpcError } = await supabase.rpc("owner_record_sales_payment", {
      p_business_id: businessId,
      p_customer_id: customerId,
      p_receiving_account_id: accountId,
      p_method: method,
      p_amount: amountValue,
      p_received_at: new Date(receivedAt).toISOString(),
      p_external_reference: method === "cash" ? null : reference.trim(),
      p_allocations: allocationDrafts.map(item => ({ invoice_id: item.invoice_id, amount: Number(item.amount) })),
      p_notes: notes.trim() || null,
      p_request_id: requestId(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      const duplicateWarning = data?.duplicate_reference_warning ? " Duplicate reference detected—check the earlier entry before proceeding." : "";
      const credit = Number(data?.customer_credit_amount ?? 0);
      setNotice("Payment " + data.payment_number + " recorded and posted. Receipt " + data.receipt_number + " issued." + (credit > 0 ? " Customer credit: " + money(credit) + "." : "") + duplicateWarning);
      setAmount(""); setReference(""); setNotes(""); setAllocationDrafts([]); setReceivedAt(localDateTime());
      await load(); onChanged();
      const nextReceipt = (await supabase.from("receipts").select("id,receipt_number,payment_id,customer_name_snapshot,amount,issued_at").eq("business_id", businessId).eq("payment_id", data.payment_id).maybeSingle()).data as Receipt | null;
      if (nextReceipt) setReceipt(nextReceipt);
    }
    setBusy(false);
  }

  async function reconcilePayment(payment: Payment) {
    if (!supabase) return;
    const statementReference = window.prompt("Statement, Paybill statement or cash-book reference (optional):");
    if (statementReference === null) return;
    const reconciliationNotes = window.prompt("Reconciliation notes (optional):") ?? "";
    const reconciliationDate = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Nairobi" }).format(new Date());
    setBusy(true); setError(""); setNotice("");
    const { error: rpcError } = await supabase.rpc("owner_reconcile_sales_payment", {
      p_payment_id: payment.id, p_reconciliation_date: reconciliationDate,
      p_statement_reference: statementReference.trim() || null,
      p_notes: reconciliationNotes.trim() || null, p_request_id: requestId(),
    });
    if (rpcError) setError(rpcError.message);
    else { setNotice(payment.payment_number + " marked as manually reconciled."); await load(); onChanged(); }
    setBusy(false);
  }

  async function recordRefund(event: FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    const amountValue = Number(refundAmount);
    const payment = payments.find(item => item.id === refundPayment);
    if (!payment || payment.receiving_account_id || payment.status !== "posted" || !Number.isSafeInteger(amountValue) || amountValue <= 0 || !refundReason.trim()) {
      setError("Choose a posted legacy order payment and enter a positive amount and reason."); return;
    }
    if (refundBucket === "allocated" && !refundAllocation) { setError("Choose the order allocation being refunded."); return; }
    setBusy(true); setError(""); setNotice("");
    const { error: rpcError } = await supabase.rpc("owner_record_refund", {
      p_payment_id: refundPayment, p_allocation_id: refundBucket === "allocated" ? refundAllocation : null,
      p_source_bucket: refundBucket, p_amount: amountValue, p_reason: refundReason.trim(),
      p_refund_method: refundMethod, p_external_reference: refundReference.trim() || null, p_request_id: requestId(),
    });
    if (rpcError) setError(rpcError.message);
    else { setNotice("Legacy order refund recorded as pending. Posting remains a separate owner action."); setRefundAmount(""); setRefundReason(""); setRefundReference(""); await load(); onChanged(); }
    setBusy(false);
  }

  async function refundAction(refund: Refund, action: "post" | "cancel") {
    if (!supabase) return;
    const cancellationReason = action === "cancel" ? window.prompt("Reason for cancelling this pending refund:") : null;
    if (action === "cancel" && !cancellationReason?.trim()) return;
    setBusy(true); setError(""); setNotice("");
    const result = action === "post"
      ? await supabase.rpc("owner_post_refund", { p_refund_id: refund.id, p_request_id: requestId() })
      : await supabase.rpc("owner_cancel_refund", { p_refund_id: refund.id, p_reason: cancellationReason!.trim(), p_request_id: requestId() });
    if (result.error) setError(result.error.message);
    else setNotice(action === "post" ? "Legacy refund posted and audited." : "Pending legacy refund cancelled and audited.");
    await load(); onChanged(); setBusy(false);
  }

  async function applyCustomerCredit(event: FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    const amountValue = Number(creditAmount);
    if (!creditCustomerId || !creditInvoiceId || !Number.isSafeInteger(amountValue) || amountValue <= 0) {
      setError("Choose a customer, invoice and positive whole-KES credit amount."); return;
    }
    setBusy(true); setError(""); setNotice("");
    const { data, error: rpcError } = await supabase.rpc("owner_apply_sales_customer_credit", {
      p_business_id: businessId, p_customer_id: creditCustomerId, p_invoice_id: creditInvoiceId,
      p_amount: amountValue, p_request_id: requestId(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      setNotice(money(Number(data.amount_applied)) + " customer credit applied to " + invoices.find(invoice => invoice.id === creditInvoiceId)?.invoice_number + ".");
      setCreditAmount(""); setCreditInvoiceId("");
      await load(); onChanged();
    }
    setBusy(false);
  }

  function printReceipt(item: Receipt) {
    setReceipt(item);
    window.setTimeout(() => window.print(), 100);
  }

  const postedPayments = payments.filter(payment => payment.status === "posted");
  const reconciledAmount = postedPayments.filter(payment => reconciliationFor(payment.id)).reduce((sum, payment) => sum + Number(payment.amount), 0);
  const unreconciledAmount = postedPayments.filter(payment => payment.receiving_account_id && !reconciliationFor(payment.id)).reduce((sum, payment) => sum + Number(payment.amount), 0);

  return <section className="connected-panel payment-workflow">
    <div className="panel-toolbar"><div><h2>Payments and reconciliation</h2><p>Record every payment manually, allocate it to invoices and reconcile it against the receiving account.</p></div><button className="secondary-action" type="button" onClick={() => void load()}>Refresh</button></div>
    {error && <div className="notice error" role="alert">{error}</div>}
    {notice && <div className="notice success" role="status">{notice}</div>}

    <div className="payment-metrics">
      <article><span>Payments posted</span><b>{money(postedPayments.reduce((sum, payment) => sum + Number(payment.amount), 0))}</b></article>
      <article><span>Manually reconciled</span><b>{money(reconciledAmount)}</b></article>
      <article><span>Unreconciled in accounts</span><b>{money(unreconciledAmount)}</b></article>
    </div>

    <div className="payment-section">
      <h3>Receiving accounts</h3>
      <p>Set up the shop cash drawer, M-Pesa Paybill, bank accounts and cheque-clearing account. Account types cannot be changed after payments have been recorded.</p>
      <form className="record-form" onSubmit={createAccount}>
        <label>Account name *<input required maxLength={100} value={accountName} onChange={event => setAccountName(event.target.value)} placeholder="e.g. Shop cash drawer" /></label>
        <label>Account type<select value={accountType} onChange={event => setAccountType(event.target.value as AccountType)}><option value="cash">Cash</option><option value="mpesa_paybill">M-Pesa Paybill</option><option value="bank">Bank</option><option value="cheque_clearing">Cheque clearing</option></select></label>
        <label>Account / Paybill reference<input maxLength={160} value={accountReference} onChange={event => setAccountReference(event.target.value)} placeholder="Account number or Paybill number" /></label>
        {accountType === "bank" && <label>Bank name *<input required maxLength={120} value={bankName} onChange={event => setBankName(event.target.value)} /></label>}
        <div className="form-actions"><button className="primary-action compact" disabled={busy || !accountName.trim()}>{busy ? "Saving…" : "＋ Add receiving account"}</button></div>
      </form>
      <div className="record-list">{accountTotals.map(account => <article className="record-row" key={account.id}><div><b>{account.account_name}</b><small>{account.account_type.replace("_", " ")}{account.account_reference ? " · " + account.account_reference : ""}{account.bank_name ? " · " + account.bank_name : ""}</small></div><div><b>{money(account.total)}</b><small>{money(account.reconciled)} reconciled · {money(account.unreconciled)} unreconciled · {account.count} payments</small></div></article>)}{!accounts.length && <p className="empty-records">Add a receiving account before recording payments.</p>}</div>
    </div>

    <div className="payment-section">
      <h3>Record a manual payment</h3>
      <form className="record-form" onSubmit={recordPayment}>
        <label>Customer *<select required value={customerId} onChange={event => { setCustomerId(event.target.value); setAllocationDrafts([]); }}><option value="">Choose customer</option>{customers.map(customer => <option key={customer.id} value={customer.id}>{customer.display_name}</option>)}</select></label>
        <label>Payment method<select value={method} onChange={event => { setMethod(event.target.value as Method); setReference(""); }}><option value="cash">Cash</option><option value="mpesa_manual">M-Pesa Paybill</option><option value="bank_transfer">Bank transfer</option><option value="cheque">Cheque</option></select></label>
        <label>Receiving account *<select required value={accountId} onChange={event => setAccountId(event.target.value)}><option value="">Choose account</option>{validAccounts.map(account => <option key={account.id} value={account.id}>{account.account_name}</option>)}</select></label>
        <label>Amount received (KES) *<input required type="number" min="1" step="1" value={amount} onChange={event => setAmount(event.target.value)} /></label>
        <label>Payment date and time *<input required type="datetime-local" value={receivedAt} onChange={event => setReceivedAt(event.target.value)} /></label>
        {method !== "cash" && <label>{method === "mpesa_manual" ? "M-Pesa transaction code *" : method === "bank_transfer" ? "Bank transaction reference *" : "Cheque number *"}<input required maxLength={160} minLength={method === "mpesa_manual" ? 6 : 1} value={reference} onChange={event => setReference(event.target.value.toUpperCase())} /></label>}
        <label className="wide-field">Notes<textarea maxLength={4000} value={notes} onChange={event => setNotes(event.target.value)} /></label>
        <div className="wide-field">
          <div className="panel-toolbar"><div><h3>Invoice allocations</h3><p>Allocate all or part of this payment. Any unallocated balance becomes customer credit.</p></div><button type="button" className="secondary-action" disabled={!customerInvoices.length} onClick={() => setAllocationDrafts(current => [...current, { invoice_id: "", amount: "" }])}>＋ Add invoice</button></div>
          {allocationDrafts.map((item, index) => <div className="record-form" key={index}>
            <label>Invoice<select required value={item.invoice_id} onChange={event => setAllocationDrafts(current => current.map((row, i) => i === index ? { ...row, invoice_id: event.target.value } : row))}><option value="">Choose invoice</option>{customerInvoices.filter(invoice => !allocationDrafts.some((row, i) => i !== index && row.invoice_id === invoice.id)).map(invoice => <option key={invoice.id} value={invoice.id}>{invoice.invoice_number} · Due {money(invoiceBalance(invoice))} · {invoice.status}</option>)}</select></label>
            <label>Allocate (KES)<input type="number" min="1" step="1" value={item.amount} onChange={event => setAllocationDrafts(current => current.map((row, i) => i === index ? { ...row, amount: event.target.value } : row))} /></label>
            <div className="form-actions"><button type="button" className="text-action" onClick={() => setAllocationDrafts(current => current.filter((_, i) => i !== index))}>Remove allocation</button></div>
          </div>)}
          {customerId && <p className="balance-inline">Available customer credit: <b>{money(customerCredit(customerId))}</b> · Allocated now: <b>{money(allocationTotal)}</b>{amount && Number(amount) > allocationTotal ? " · To customer credit: " + money(Math.max(Number(amount) - allocationTotal, 0)) : ""}</p>}
          {!customerInvoices.length && customerId && <p className="empty-records">This customer has no issued invoices with an outstanding balance. You can still record an unallocated advance as customer credit.</p>}
        </div>
        <div className="form-actions"><button className="primary-action compact" disabled={busy || !validAccounts.length}>{busy ? "Saving…" : "Record and post payment"}</button></div>
      </form>
    </div>

    <div className="payment-section">
      <h3>Legacy order refunds and corrections</h3>
      <p>These controls are retained for older order-payment records without a Sales receiving account. New Sales payments use invoice allocations and customer credit.</p>
      <form className="record-form" onSubmit={recordRefund}>
        <label>Posted legacy payment *<select required value={refundPayment} onChange={event => { setRefundPayment(event.target.value); setRefundAllocation(""); }}><option value="">Choose payment</option>{payments.filter(payment => payment.status === "posted" && !payment.receiving_account_id).map(payment => <option key={payment.id} value={payment.id}>{payment.payment_number} · {money(payment.amount)}</option>)}</select></label>
        <label>Refund source<select value={refundBucket} onChange={event => setRefundBucket(event.target.value as "allocated" | "unallocated")}><option value="allocated">Amount allocated to an order</option><option value="unallocated">Unallocated payment amount</option></select></label>
        {refundBucket === "allocated" && <label>Order allocation *<select required value={refundAllocation} onChange={event => setRefundAllocation(event.target.value)}><option value="">Choose allocation</option>{legacyAllocations.filter(allocation => allocation.payment_id === refundPayment).map(allocation => <option key={allocation.id} value={allocation.id}>{orders.find(order => order.id === allocation.order_id)?.order_number ?? "Order"} · {money(allocation.amount)}</option>)}</select></label>}
        <label>Refund amount (KES) *<input required type="number" min="1" step="1" value={refundAmount} onChange={event => setRefundAmount(event.target.value)} /></label>
        <label>Refund method<select value={refundMethod} onChange={event => setRefundMethod(event.target.value as "cash" | "mpesa")}><option value="mpesa">M-Pesa</option><option value="cash">Cash</option></select></label>
        <label>Refund reference<input value={refundReference} onChange={event => setRefundReference(event.target.value)} placeholder="M-Pesa code / cash voucher" /></label>
        <label className="wide-field">Reason *<textarea required value={refundReason} onChange={event => setRefundReason(event.target.value)} /></label>
        <div className="form-actions"><button className="primary-action compact" disabled={busy || !refundPayment}>Record pending legacy refund</button></div>
      </form>
      <div className="record-list">{refunds.map(refund => <article className="record-row" key={refund.id}><div><b>{money(refund.amount)} · {refund.refund_method.toUpperCase()} · {refund.source_bucket}</b><small>{refund.reason} · {new Date(refund.created_at).toLocaleString("en-KE")} · {payments.find(payment => payment.id === refund.payment_id)?.payment_number ?? "Payment"}</small></div><div className="payment-actions"><span className={"status-chip " + refund.status}>{refund.status}</span>{refund.status === "pending" && <><button type="button" className="primary-action compact" disabled={busy} onClick={() => void refundAction(refund, "post")}>Post refund</button><button type="button" className="secondary-action" disabled={busy} onClick={() => void refundAction(refund, "cancel")}>Cancel</button></>}</div></article>)}{!refunds.length && <p className="empty-records">No legacy refunds recorded.</p>}</div>
    </div>

    <div className="payment-section">
      <h3>Apply customer credit</h3>
      <p>Overpayments and unallocated advances remain as customer credit until you choose to apply them to an issued invoice.</p>
      <form className="record-form" onSubmit={applyCustomerCredit}>
        <label>Customer *<select required value={creditCustomerId} onChange={event => { setCreditCustomerId(event.target.value); setCreditInvoiceId(""); }}><option value="">Choose customer</option>{customers.filter(customer => customerCredit(customer.id) > 0).map(customer => <option key={customer.id} value={customer.id}>{customer.display_name} · {money(customerCredit(customer.id))} credit</option>)}</select></label>
        <label>Invoice *<select required value={creditInvoiceId} onChange={event => setCreditInvoiceId(event.target.value)}><option value="">Choose invoice</option>{invoices.filter(invoice => invoice.customer_id === creditCustomerId && invoiceBalance(invoice) > 0).map(invoice => <option key={invoice.id} value={invoice.id}>{invoice.invoice_number} · Balance {money(invoiceBalance(invoice))}</option>)}</select></label>
        <label>Credit to apply (KES) *<input required type="number" min="1" step="1" value={creditAmount} onChange={event => setCreditAmount(event.target.value)} /></label>
        <div className="form-actions"><button className="primary-action compact" disabled={busy || !creditCustomerId || !creditInvoiceId}>Apply customer credit</button></div>
      </form>
    </div>

    <div className="payment-section">
      <h3>Account reconciliation</h3>
      <p>Mark a payment reconciled only after checking it against the relevant Paybill or bank statement, or the physical cash record. Nothing is imported or matched automatically.</p>
      <div className="record-list">{payments.filter(payment => payment.status === "posted" && payment.receiving_account_id).map(payment => {
        const account = accounts.find(item => item.id === payment.receiving_account_id);
        const reconciliation = reconciliationFor(payment.id);
        return <article className="record-row" key={payment.id}><div><b>{payment.payment_number} · {money(payment.amount)}</b><small>{account?.account_name ?? "Receiving account"} · {methodLabel[payment.method]} · {new Date(payment.received_at).toLocaleString("en-KE")}</small>{reconciliation && <small>Reconciled {reconciliation.reconciliation_date}{reconciliation.statement_reference ? " · " + reconciliation.statement_reference : ""}</small>}</div><div className="payment-actions"><span className={"status-chip " + (reconciliation ? "posted" : "pending")}>{reconciliation ? "Reconciled" : "Unreconciled"}</span>{!reconciliation && <button type="button" className="secondary-action" disabled={busy} onClick={() => void reconcilePayment(payment)}>Reconcile</button>}</div></article>;
      })}{!payments.some(payment => payment.status === "posted" && payment.receiving_account_id) && <p className="empty-records">No manually entered account payments yet.</p>}</div>
    </div>

    <div className="payment-section">
      <h3>Payment history and receipts</h3>
      <div className="record-list">{payments.map(payment => {
        const rec = receipts.find(item => item.payment_id === payment.id);
        const account = accounts.find(item => item.id === payment.receiving_account_id);
        const reconciliation = reconciliationFor(payment.id);
        const methodText = methodLabel[payment.method] ?? payment.method;
        const invoiceNames = allocations.filter(allocation => allocation.payment_id === payment.id).map(allocation => invoices.find(invoice => invoice.id === allocation.invoice_id)?.invoice_number).filter(Boolean).join(", ");
        return <article className="record-row" key={payment.id}><div><b>{payment.payment_number} · {money(payment.amount)}</b><small>{rec?.customer_name_snapshot ?? "Customer payment"} · {methodText} · {new Date(payment.received_at).toLocaleString("en-KE")} · {account?.account_name ?? "Legacy payment / no receiving account"} · {payment.mpesa_reference || payment.external_reference || "No reference"}</small>{invoiceNames && <small>Allocated to: {invoiceNames}</small>}{payment.duplicate_reference_warning && <span className="status-chip pending">Duplicate reference — review</span>}</div><div className="payment-actions"><span className={"status-chip " + payment.status}>{payment.status.replace("_", " ")}</span>{payment.receiving_account_id && <span className={"status-chip " + (reconciliation ? "posted" : "pending")}>{reconciliation ? "Reconciled" : "Unreconciled"}</span>}{rec && <button type="button" className="secondary-action" onClick={() => printReceipt(rec)}>Receipt {rec.receipt_number}</button>}</div></article>;
      })}{!payments.length && <p className="empty-records">No payments recorded.</p>}</div>
    </div>

    {receipt && <div className="receipt-print"><div className="receipt-paper"><p className="eyebrow">MJ PRINTING & BRANDING</p><h2>OFFICIAL RECEIPT</h2><h3>{receipt.receipt_number}</h3><hr /><p>Received from: <b>{receipt.customer_name_snapshot}</b></p><p>Amount received: <b>{money(receipt.amount)}</b></p><p>Date: {new Date(receipt.issued_at).toLocaleString("en-KE")}</p><p>Payment reference: {payments.find(payment => payment.id === receipt.payment_id)?.payment_number}</p><p>Thank you for your business.</p><button type="button" className="secondary-action no-print" onClick={() => setReceipt(null)}>Close receipt</button></div></div>}
  </section>;
}
