import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const app = await readFile(new URL('../src/App.tsx', import.meta.url), 'utf8');
const migration = await readFile(new URL('../supabase/migrations/20261120180000_production_schedule_quality_handover.sql', import.meta.url), 'utf8');
const styles = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');

test('calendar loads quotations on their issue date and jobs on creation and scheduled dates', () => {
  assert.match(operations, /from\('quotations'\)\.select\('id,quote_number,status,total,customer_id,created_at,issue_date,valid_until,revision_number'\)/);
  assert.match(operations, /from\('production_jobs'\)\.select\('id,job_number,job_name,production_status,customer_id,created_at,expected_start_at,expected_completion_at,delivery_at,delay_reason,customer_supplied_items'\)/);
  for (const event of ['job_created','expected_start','expected_completion','delivery']) assert.ok(operations.includes("event_type:'"+event+"'"), event+' is represented');
  assert.match(migration, /production_jobs_calendar_start_idx/);
  assert.match(migration, /production_jobs_calendar_completion_idx/);
  assert.match(migration, /production_jobs_calendar_delivery_idx/);
});

test('calendar supports month, week and day navigation, search and record-type filters', () => {
  assert.match(operations, /useState<'month'\|'week'\|'day'>\('month'\)/);
  assert.match(operations, /calendarView==='month'\?42:calendarView==='week'\?7:1/);
  assert.match(operations, /calendarSearch/);
  assert.match(operations, /calendarFilter/);
  assert.match(operations, /Quotations only/);
  assert.match(operations, /Production jobs only/);
  assert.match(operations, /Previous calendar period/);
  assert.match(operations, /Next calendar period/);
});

test('calendar events open the exact quotation or production job and highlight the selected record', () => {
  assert.match(operations, /setSelectedCalendarEvent\(event\)/);
  assert.match(operations, /onNavigate\?\.\(selectedCalendarEvent\.record_type==='quotation'\?'sales':'production',selectedCalendarEvent\.record_id\)/);
  assert.match(operations, /recordId===q\.id\?/);
  assert.match(operations, /recordId===j\.id\?/);
  assert.match(app, /function navigate\(target:Page,id\?:string\)/);
  assert.match(app, /onNavigate=\{navigate\} recordId=\{recordId\}/);
});


test('calendar views have responsive layout, event colours and a usable mobile record panel', () => {
  for (const selector of ['.calendar-toolbar','.calendar-weekdays','.calendar-grid-month','.calendar-grid-week','.calendar-grid-day','.calendar-event.calendar-status-green','.calendar-event.calendar-status-orange','.calendar-selected']) {
    assert.ok(styles.includes(selector), selector+' is styled');
  }
  assert.match(styles, /@media\(max-width:680px\)/);
});

test('calendar refreshes when quotation or production job records change', () => {
  assert.match(operations, /table:'quotations',filter:'business_id=eq\.'\+businessId/);
  assert.match(operations, /table:'production_jobs',filter:'business_id=eq\.'\+businessId/);
  assert.match(operations, /removeChannel\(channel\)/);
});
