#!/usr/bin/env python3
"""Dependency-free helpers for safe diff-aware Flutter CI, log regression and APK audits."""
from __future__ import annotations
import argparse, hashlib, json, os, re, sys, zipfile
from pathlib import Path, PurePosixPath
from typing import Any

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
NOISE = re.compile(r"Caught exception: Already watching path: .+/android\s*\Z", re.I)
RULES = {
 "errors": re.compile(r"::error::|##\[error\]|\berror\s*[•:]|\berror:", re.I),
 "warnings": re.compile(r"::warning::|##\[warning\]|\bwarning\s*[•:]|\bwarning:", re.I),
 "exceptions": re.compile(r"Traceback \(most recent call last\)|\bException\b|Caught exception", re.I),
 "known_flutter_tool_noise": NOISE,
 "infrastructure": re.compile(r"Gradle task .* failed|SDK location not found|Could not resolve .*|connection timed out|HTTP 5\d\d|No space left on device|emulator.*(offline|failed)|INSTALL_FAILED_", re.I),
 "info_lints": re.compile(r"\binfo\s*•", re.I),
}
DOC_EXT={".md",".rst",".adoc"}
DOC_ROOTS={"docs","documentation"}
CRITICAL_ROOTS={"android","ios","web","windows","macos","linux","integration_test",".github","tool","tools","scripts","assets","fonts"}
CRITICAL_FILES={"pubspec.yaml","pubspec.lock","pubspec_overrides.yaml","analysis_options.yaml","melos.yaml","build.yaml","Makefile","justfile","Gemfile","Podfile.lock"}
CRITICAL_NAME=re.compile(r"(^|/)(gradle\.properties|settings\.gradle(\.kts)?|build\.gradle(\.kts)?|Podfile|Info\.plist|AndroidManifest\.xml|CMakeLists\.txt)$",re.I)

def change_impact(changed:list[str],*,event:str,targeted:bool,force_full:bool=False,test_root:Path=Path("test"))->dict[str,Any]:
 paths=sorted({p.replace("\\","/").lstrip("/") for p in changed if p.strip()})
 r={"mode":"full","reason":"","changed_files":paths,"target_tests":[]}
 if force_full: r["reason"]="A configured quality gate requires complete-suite coverage; targeted PR tests are disabled for this run."; return r
 if event!="pull_request": r["reason"]="Push, release and manual runs always require the full test suite."; return r
 if not targeted: r["reason"]="Targeted PR testing is disabled; full test suite retained."; return r
 if not paths: r["reason"]="Changed paths unavailable; fail-safe full suite."; return r
 if all(PurePosixPath(p).suffix.lower() in DOC_EXT or p.lower() in {"license","license.md","changelog.md"} for p in paths):
  r.update(mode="skip",reason="Documentation-only change; Flutter unit/widget tests can be skipped."); return r
 for p in paths:
  parts=PurePosixPath(p).parts
  if p in CRITICAL_FILES or (parts and parts[0] in CRITICAL_ROOTS) or CRITICAL_NAME.search(p):
   r["reason"]=f"Critical platform/configuration/tooling/workflow/asset change ({p}); run all tests."; return r
  if p in {"lib/main.dart","lib/app.dart","lib/router.dart","lib/routes.dart","lib/theme.dart"}:
   r["reason"]=f"Shared application entry point changed ({p}); run all tests."; return r
  if not (p.startswith("lib/") and p.endswith(".dart") or p.startswith("test/") and p.endswith("_test.dart")):
   r["reason"]=f"Runtime impact unclear for {p}; fail-safe full suite."; return r
 tests={p for p in paths if p.startswith("test/") and p.endswith("_test.dart")}
 all_tests=sorted(("test/"+str(p.relative_to(test_root)).replace(chr(92),"/")) for p in test_root.rglob("*_test.dart")) if test_root.is_dir() else []
 for source in [p for p in paths if p.startswith("lib/") and p.endswith(".dart")]:
  stem=PurePosixPath(source).stem.lower()
  direct="test/"+str(PurePosixPath(source).relative_to("lib").with_name(stem+"_test.dart"))
  candidates=[direct] if direct in all_tests else [p for p in all_tests if stem in PurePosixPath(p).stem.lower().replace("_test","").split("_")]
  if not candidates: r["reason"]=f"No direct test mapping found for {source}; fail-safe full suite."; return r
  tests.update(candidates)
 if tests: r.update(mode="targeted",reason="Confident Dart-to-test mapping found. Pushes/releases always run the complete suite.",target_tests=sorted(tests)); return r
 r["reason"]="No confident test selection was possible; fail-safe full suite."; return r

def cmd_impact(a):
 changed=Path(a.changed_file).read_text(encoding="utf-8",errors="replace").splitlines() if a.changed_file and Path(a.changed_file).is_file() else []
 result=change_impact(changed,event=a.event or os.getenv("GITHUB_EVENT_NAME",""),targeted=a.targeted_tests,force_full=a.min_coverage>0)
 out=Path(a.output_dir); out.mkdir(parents=True,exist_ok=True)
 (out/"change-impact.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
 lines=["# Change impact analysis","",f"- Event: {a.event or 'unknown'}",f"- Test mode: {result['mode']}",f"- Changed paths: {len(result['changed_files'])}","",result["reason"],"","## Changed paths",""]
 lines += [f"- {p}" for p in result["changed_files"][:300]] or ["- (none returned)"]
 if len(result["changed_files"])>300: lines.append(f"- Display capped at 300 of {len(result['changed_files'])}; JSON retains all paths.")
 lines += ["","## Selected tests",""]+[f"- {p}" for p in result["target_tests"]] or ["- (not applicable)"]
 (out/"change-impact.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
 dest=os.getenv("GITHUB_OUTPUT")
 if dest:
  with open(dest,"a",encoding="utf-8") as f:
   f.write(f"mode={result['mode']}\n"); f.write("test_files<<HYOUKA_TESTS\n"+"\n".join(result["target_tests"])+"\nHYOUKA_TESTS\n")
 print(f"Change impact mode={result['mode']}: {result['reason']}")
 return 0

def warning_signatures(paths:list[Path])->list[str]:
 seen=set()
 for path in paths:
  try: lines=path.read_text(encoding="utf-8",errors="replace").splitlines()
  except OSError: continue
  for raw in lines:
   line=ANSI.sub("",raw).strip()
   if not RULES["warnings"].search(line) or NOISE.search(line): continue
   line=re.sub(r"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-]+Z?\b","<timestamp>",line)
   line=re.sub(r"((?:[A-Za-z0-9_./-]+\.dart):)\d+:\d+",r"\1<line>:<column>",line)
   seen.add(re.sub(r"\s+"," ",line)[:1000])
 return sorted(seen)

def cmd_logs(a):
 root=Path(a.log_root); out=Path(a.output_dir); out.mkdir(parents=True,exist_ok=True)
 logs=sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in {".log",".txt"} and p.name not in {"log-analysis.md","log-analysis.json"})
 counts={k:0 for k in RULES}; matched=[]; unique={}
 for path in logs:
  for n,raw in enumerate(path.read_text(encoding="utf-8",errors="replace").splitlines(),1):
   line=ANSI.sub("",raw); cats=[k for k,rx in RULES.items() if rx.search(line)]
   if not cats: continue
   for key in cats: counts[key]+=1; unique.setdefault(key,set()).add(re.sub(r"\s+"," ",line.strip())[:1000])
   matched.append({"file":str(path),"line":n,"categories":cats,"text":line[:2000]})
 sigs=warning_signatures(logs); base=Path(a.baseline) if a.baseline else None; base_ok=bool(base and base.is_file()); base_sigs=[]
 if base_ok:
  try:
   val=json.loads(base.read_text(encoding="utf-8")); base_sigs=val.get("signatures",[]) if isinstance(val,dict) else val if isinstance(val,list) else []
  except (OSError,ValueError): base_ok=False
 new=sorted(set(sigs)-set(base_sigs))
 data={"log_files_analyzed":len(logs),"counts":counts,"unique_signatures_by_category":{k:len(v) for k,v in unique.items()},"unique_warning_signatures":sigs,"baseline_available":base_ok,"new_warning_signatures":new,"new_warning_count":len(new),"findings":matched[:5000],"finding_count":len(matched),"note":"Pattern matches are diagnostic signals, not proof of root cause. Original logs are preserved unchanged."}
 (out/"log-analysis.json").write_text(json.dumps(data,indent=2)+"\n",encoding="utf-8")
 (out/"warning-signatures.json").write_text(json.dumps({"signatures":sigs},indent=2)+"\n",encoding="utf-8")
 lines=["# Log diagnostics and warning regression","",f"- Logs analyzed: {len(logs)}",f"- Matched lines: {len(matched)}",f"- Warning signatures: {len(sigs)}",f"- Previous baseline: {'available' if base_ok else 'not available; this run establishes it'}",f"- New warning signatures: {len(new)}","","| Classification | Lines | Unique lines |","|---|---:|---:|"]
 lines += [f"| {k} | {counts[k]} | {len(unique.get(k,set()))} |" for k in RULES]
 lines += ["","## New warning signatures",""]+[f"- {x}" for x in new[:300]]
 if len(new)>300: lines.append(f"- Display capped at 300 of {len(new)}.")
 lines += ["","Pattern matches do not prove root cause. Original logs are not modified.",""]
 (out/"log-analysis.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
 print(json.dumps({"log_files":len(logs),"counts":counts,"new_warning_count":len(new),"baseline_available":base_ok}))
 if a.fail_on_new_warnings and base_ok and new:
  print(f"::error::Detected {len(new)} new warning signatures compared with the previous build baseline.",file=sys.stderr); return 1
 return 0

def parse_badging(path):
 meta={}; perms=[]
 if path and Path(path).is_file():
  t=Path(path).read_text(encoding="utf-8",errors="replace")
  patterns={"application_id":r"^package: name='([^']+)'","version_code":r"^package:.*?versionCode='([^']*)'","version_name":r"^package:.*?versionName='([^']*)'","min_sdk":r"^sdkVersion:'([^']*)'","target_sdk":r"^targetSdkVersion:'([^']*)'"}
  for key,pat in patterns.items():
   m=re.search(pat,t,re.M)
   if m: meta[key]=m.group(1)
  perms=sorted(set(re.findall(r"^uses-permission(?:-sdk-\d+)?: name='([^']+)'",t,re.M)))
 return meta,perms

def cmd_apk(a):
 apk=Path(a.apk)
 if not apk.is_file() or apk.stat().st_size==0: print(f"APK missing or empty: {apk}",file=sys.stderr); return 2
 out=Path(a.output_dir); out.mkdir(parents=True,exist_ok=True); meta,perms=parse_badging(a.badging)
 try:
  with zipfile.ZipFile(apk) as z:
   bad=z.testzip(); infos=[i for i in z.infolist() if not i.is_dir()]
   names=[i.filename for i in infos]; abis=sorted({n.split("/")[1] for n in names if n.startswith("lib/") and len(n.split("/"))>2})
 except (OSError,zipfile.BadZipFile) as e: print(f"Unreadable APK ZIP: {e}",file=sys.stderr); return 2
 size=apk.stat().st_size; failures=[]
 if bad: failures.append(f"Archive CRC failed: {bad}")
 if a.expected_abi and abis != [a.expected_abi]: failures.append(f"Expected only ABI {a.expected_abi}; found {abis or 'no native ABI entries'}")
 forbidden={x.strip() for x in re.split(r"[,\s]+",getattr(a,"forbid_permissions","") or "") if x.strip()}
 denied=sorted(forbidden.intersection(perms))
 if denied: failures.append("Forbidden Android permissions declared: "+", ".join(denied))
 limit=float(a.max_size_mb or 0); entry_limit=float(a.max_entry_size_mb or 0)
 if limit and size>limit*1048576: failures.append(f"APK size {size/1048576:.2f} MiB exceeds {limit:.2f} MiB limit")
 large=[i for i in infos if entry_limit and i.file_size>entry_limit*1048576]
 if large: failures.append(f"{len(large)} entries exceed {entry_limit:.2f} MiB per-entry limit")
 data={"apk":str(apk),"size_bytes":size,"sha256":hashlib.sha256(apk.read_bytes()).hexdigest(),"zip_crc_valid":bad is None,"expected_abi":a.expected_abi or None,"native_abis":abis,"metadata":meta,"permissions":perms,"forbidden_permissions_checked":sorted(forbidden),"forbidden_permissions_found":denied,"largest_entries":[{"path":i.filename,"size_bytes":i.file_size} for i in sorted(infos,key=lambda x:x.file_size,reverse=True)[:20]],"max_size_mb":limit or None,"max_entry_size_mb":entry_limit or None,"failures":failures}
 (out/"apk-metadata.json").write_text(json.dumps(data,indent=2)+"\n",encoding="utf-8")
 lines=["# APK metadata and size audit","",f"- Size: {size} bytes ({size/1048576:.2f} MiB)",f"- SHA-256: {data['sha256']}",f"- ZIP CRC: {'valid' if bad is None else 'failed'}",f"- Expected ABI: {a.expected_abi or 'not constrained'}",f"- Native ABIs: {', '.join(abis) or 'none detected'}"]
 for k in ("application_id","version_name","version_code","min_sdk","target_sdk"): lines.append(f"- {k.replace('_',' ').title()}: {meta.get(k,'not available; see aapt badging log')}")
 lines += ["","## Declared permissions",""]+[f"- {p}" for p in perms or ["No permissions parsed; see aapt badging log."]]
 lines += ["","## Largest archive entries","","| Entry | Bytes | MiB |","|---|---:|---:|"]+[f"| {i['path']} | {i['size_bytes']} | {i['size_bytes']/1048576:.2f} |" for i in data["largest_entries"]]
 lines += ["","## Quality gate",""]+[f"- FAIL: {x}" for x in failures]
 if not failures: lines.append("All enabled APK archive, ABI, and size checks passed.")
 (out/"apk-audit.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
 print(json.dumps({"size_bytes":size,"sha256":data["sha256"],"native_abis":abis,"metadata":meta,"failures":failures}))
 return 1 if failures else 0

def cmd_quality(a):
 out=Path(a.output_dir); out.mkdir(parents=True,exist_ok=True); failures=[]; cov=None
 if a.min_coverage>0:
  try: cov=float(json.loads(Path(a.coverage_json).read_text(encoding="utf-8"))["coverage_percent"])
  except (OSError,ValueError,KeyError,TypeError): cov=None
  if cov is None: failures.append(f"Coverage minimum is {a.min_coverage:.2f}% but coverage data is missing/invalid")
  elif cov<a.min_coverage: failures.append(f"Coverage {cov:.2f}% is below required {a.min_coverage:.2f}%")
 apk=Path(a.apk); size=apk.stat().st_size/1048576 if apk.is_file() else None
 if a.max_apk_size>0:
  if size is None: failures.append("APK size gate enabled, but APK is missing")
  elif size>a.max_apk_size: failures.append(f"APK size {size:.2f} MiB exceeds {a.max_apk_size:.2f} MiB")
 data={}
 if a.log_analysis and Path(a.log_analysis).is_file():
  try: data=json.loads(Path(a.log_analysis).read_text(encoding="utf-8"))
  except (OSError,ValueError): data={}
 if a.fail_on_new_warnings and data.get("baseline_available") and data.get("new_warning_count",0): failures.append(f"{data['new_warning_count']} new warning signatures were detected")
 result={"coverage_percent":cov,"min_coverage_percent":a.min_coverage,"apk_size_mb":size,"max_apk_size_mb":a.max_apk_size,"new_warning_count":data.get("new_warning_count",0),"failures":failures}
 (out/"quality-gates.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
 lines=["# Configurable quality gates","",f"- Coverage: {cov if cov is not None else 'not available'}% (minimum {a.min_coverage:.2f}%; disabled at 0)",f"- APK size: {size if size is not None else 'not built'} MiB (maximum {a.max_apk_size:.2f} MiB; disabled at 0)",f"- New warning signatures: {result['new_warning_count']}","","## Result",""]+[f"- FAIL: {x}" for x in failures]
 if not failures: lines.append("All enabled quality gates passed.")
 (out/"quality-gates.md").write_text("\n".join(lines)+"\n",encoding="utf-8"); print("\n".join(lines))
 return 1 if failures else 0

def parser():
 p=argparse.ArgumentParser(description=__doc__); sub=p.add_subparsers(dest="command",required=True)
 x=sub.add_parser("impact"); x.add_argument("--event",default=""); x.add_argument("--changed-file",default=""); x.add_argument("--output-dir",default="ci-reports"); x.add_argument("--targeted-tests",action="store_true"); x.add_argument("--min-coverage",type=float,default=0); x.set_defaults(func=cmd_impact)
 x=sub.add_parser("analyze-logs"); x.add_argument("--log-root",default="ci-reports"); x.add_argument("--baseline",default=".ci-history/warning-signatures.json"); x.add_argument("--output-dir",default="ci-reports"); x.add_argument("--fail-on-new-warnings",action="store_true"); x.set_defaults(func=cmd_logs)
 x=sub.add_parser("apk-audit"); x.add_argument("--apk",required=True); x.add_argument("--badging",default=""); x.add_argument("--expected-abi",default=""); x.add_argument("--max-size-mb",type=float,default=0); x.add_argument("--max-entry-size-mb",type=float,default=0); x.add_argument("--forbid-permissions",default=""); x.add_argument("--output-dir",default="ci-reports"); x.set_defaults(func=cmd_apk)
 x=sub.add_parser("quality"); x.add_argument("--coverage-json",default="ci-reports/coverage.json"); x.add_argument("--apk",default="build/app/outputs/flutter-apk/app-release.apk"); x.add_argument("--log-analysis",default="ci-reports/log-analysis.json"); x.add_argument("--min-coverage",type=float,default=0); x.add_argument("--max-apk-size",type=float,default=0); x.add_argument("--fail-on-new-warnings",action="store_true"); x.add_argument("--output-dir",default="ci-reports"); x.set_defaults(func=cmd_quality)
 return p
if __name__=="__main__":
 a=parser().parse_args()
 for name in ("min_coverage","max_size_mb","max_entry_size_mb","max_apk_size"):
  if hasattr(a,name) and getattr(a,name)<0: raise SystemExit("Quality thresholds cannot be negative; use 0 to disable.")
 raise SystemExit(a.func(a))
