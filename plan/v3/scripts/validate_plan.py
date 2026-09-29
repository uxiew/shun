#!/usr/bin/env python3
"""Validate planning artifacts only. Never marks application tests PASS."""
from pathlib import Path
import json,re,sys
ROOT=Path(__file__).resolve().parents[1]
def load(n):return json.loads((ROOT/n).read_text(encoding='utf-8'))
def main():
 errors=[];t=load('tasks.json');v=load('verification-cases.json');sources=load('sources.json')['sources']
 tasks=t['tasks'];cases=v['cases'];ids={x['id'] for x in tasks};cids={x['id'] for x in cases}
 if len(ids)!=len(tasks):errors.append('duplicate task IDs')
 if len(cids)!=len(cases):errors.append('duplicate test IDs')
 if t['core_count']!=sum(x['phase']!='P6' for x in tasks):errors.append('core count mismatch')
 if t['deferred_count']!=sum(x['phase']=='P6' for x in tasks):errors.append('deferred count mismatch')
 graph={x['id']:x['depends_on'] for x in tasks};active=set();done=set()
 def visit(i):
  if i not in graph:errors.append('missing dependency '+i);return
  if i in active:errors.append('dependency cycle '+i);return
  if i in done:return
  active.add(i)
  for d in graph[i]:visit(d)
  active.remove(i);done.add(i)
 for x in tasks:
  visit(x['id'])
  if not set(x['test_ids'])<=cids:errors.append('unknown tests '+x['id'])
  if x['status']=='DONE' and (not x['evidence'] or not x['commit']):errors.append('DONE without evidence '+x['id'])
  if x['phase'] not in t['phase_gates']:errors.append('missing phase '+x['phase'])
 covered={i for x in tasks for i in x['test_ids']}
 if cids-covered:errors.append('unassigned cases '+str(cids-covered))
 for g in t['phase_gates'].values():
  if not set(g['requires'])<=ids:errors.append('bad gate dependency')
 if 'X13' not in graph['R30']:errors.append('combined gate bypass')
 mapping=load('legacy-task-map.json')['mapping']
 if {x['old_id'] for x in mapping}!={f'T{i:02}' for i in range(42)}:errors.append('legacy map incomplete')
 for x in mapping:
  if not set(x['new_ids'])<=ids:errors.append('invalid legacy map')
  if x.get('completion_transferred'):errors.append('forbidden completion transfer')
 sids={x['id'].lower() for x in sources}
 if len(sids)!=len(sources):errors.append('source IDs duplicate')
 for p in ROOT.rglob('*.md'):
  text=p.read_text(encoding='utf-8')
  if text.count('```')%2:errors.append('unclosed code fence '+str(p.relative_to(ROOT)))
  for target in re.findall(r'\[[^\]\n]+\]\(([^)\s]+)\)',text):
   if target.startswith(('http://','https://','mailto:','sandbox:','#')):continue
   path,_,fragment=target.partition('#');q=(p.parent/path).resolve()
   if not q.exists():errors.append('broken link '+str(p.relative_to(ROOT))+' -> '+target)
   if re.fullmatch(r's\d+',fragment) and fragment not in sids:errors.append('unknown source '+fragment)
 taskdoc=(ROOT/'docs/08-implementation-tasks.md').read_text()
 documented=set(re.findall(r'^## ([RX]\d{2}) ',taskdoc,re.M))
 if documented!=ids:errors.append('task markdown IDs mismatch')
 schema_tests=0
 try:
  from jsonschema import Draft202012Validator, ValidationError
  validator=Draft202012Validator(load('contracts/plugin-manifest.schema.json'))
  for p in (ROOT/'contracts/examples').glob('*.json'):
   data=json.loads(p.read_text());validator.validate(data);schema_tests+=1
   bad=dict(data);bad['exec']='arbitrary-shell'
   try:validator.validate(bad);errors.append('schema permitted extra exec')
   except ValidationError:schema_tests+=1
 except ImportError:errors.append('jsonschema missing; install for schema checks')
 result=dict(scope='PLANNING_FILES_ONLY',application_tests_executed=False,passed=not errors,tasks=len(tasks),core_tasks=t['core_count'],deferred_tasks=t['deferred_count'],verification_cases=len(cases),sources=len(sources),legacy_tasks_mapped=len(mapping),schema_example_checks=schema_tests,errors=errors)
 print(json.dumps(result,ensure_ascii=False,indent=2));return bool(errors)
if __name__=='__main__':sys.exit(main())
