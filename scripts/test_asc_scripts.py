#!/usr/bin/env python3
"""Offline tests for the App Store Connect release scripts (asc_submit, asc_preflight, release.sh's
argument parsing): App Store Connect is a fake, no key, no network.

    python3 scripts/test_asc_scripts.py

The asc_submit and release.sh tests are ported from beer-llama-ios/scripts/test_asc_scripts.py;
PreflightTests is shared with it too (keep the two in step).
"""
import contextlib, importlib.util, io, os, shutil, subprocess, sys, tempfile, unittest, urllib.parse, urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["ASC_KEY_PATH"] = "/nonexistent/AuthKey.p8"   # any real call would fail loudly


def _no_network(*args, **kwargs):
    raise AssertionError("a test reached urllib.request.urlopen: App Store Connect must stay faked")


urllib.request.urlopen = _no_network   # second guard: even a call made with a key never leaves the machine

VERSION, BUILD, OLD_VERSION, OLD_BUILD, NEXT_VERSION = "2.7", "15", "2.6", "14", "2.8"


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSubmitASC:
    """Answers asc_submit's calls: one version, one VALID build, the given open submissions."""

    def __init__(self, ver_state="PREPARE_FOR_SUBMISSION", subs=(), cancel_status=200, cancel_sticks=True):
        self.ver_state = ver_state
        self.subs = dict(subs)                    # {submission id: state}
        self.cancel_status = cancel_status
        self.cancel_sticks = cancel_sticks        # False: ASC accepts the cancel but the submission stays open
        self.calls = []

    @property
    def writes(self):
        return [(m, p, b) for m, p, b in self.calls if m != "GET"]

    def __call__(self, method, path, body=None):
        self.calls.append((method, path.split("?")[0], body))
        if method == "GET":
            if "/appStoreVersions?" in path:
                return 200, {"data": [{"id": "v1", "attributes": {"versionString": VERSION,
                                                                  "appStoreState": self.ver_state}}]}
            if path.startswith("/v1/builds?"):
                return 200, {"data": [{"id": "b1", "attributes": {"version": BUILD,
                                                                  "processingState": "VALID"}}]}
            if "/reviewSubmissions?" in path:
                return 200, {"data": [{"id": i, "attributes": {"state": st}} for i, st in self.subs.items()]}
            if path.endswith("/appStoreReviewDetail"):
                return 200, {"data": None}
            raise AssertionError(f"unexpected GET {path}")
        attributes = (body or {}).get("data", {}).get("attributes", {})
        if method == "PATCH" and path.startswith("/v1/reviewSubmissions/") and attributes.get("canceled"):
            if self.cancel_status != 200:
                return self.cancel_status, {"errors": [{"code": "STATE_ERROR"}]}
            if self.cancel_sticks:
                self.subs[path.rsplit("/", 1)[1]] = "CANCELED"
            return 200, {"data": {"attributes": {}}}
        if method == "PATCH" and path.startswith("/v1/reviewSubmissions/") and attributes.get("submitted"):
            return 200, {"data": {"attributes": {"state": "WAITING_FOR_REVIEW"}}}
        if method == "PATCH" and path.endswith("/relationships/build"):
            return 204, {}
        if method == "POST" and path == "/v1/reviewSubmissions":
            return 201, {"data": {"id": "new-sub"}}
        if method == "POST" and path in ("/v1/reviewSubmissionItems", "/v1/appStoreReviewDetails"):
            return 201, {"data": {"id": "new-id"}}
        raise AssertionError(f"unexpected {method} {path}")


class SubmitTests(unittest.TestCase):
    def setUp(self):
        self.sub = load("asc_submit")

    def run_main(self, fake, *args):
        self.sub.call = fake
        argv, sys.argv = sys.argv, ["asc_submit.py", *args]
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), mock.patch.object(self.sub.time, "sleep", lambda s: None):
                self.sub.main()
        finally:
            sys.argv = argv
        return out.getvalue()

    def assertStopsBeforeAnyCall(self, *args, code=None):
        fake = FakeSubmitASC()
        with self.assertRaises(SystemExit) as stop:
            self.run_main(fake, *args)
        self.assertEqual(fake.calls, [])
        if code is not None:
            self.assertEqual(stop.exception.code, code)

    def test_help_prints_usage_and_makes_no_call(self):
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                fake = FakeSubmitASC()
                self.assertIn("Usage:", self.run_main(fake, flag))
                self.assertEqual(fake.calls, [])

    def test_an_unknown_flag_stops_before_any_call(self):
        for args in (["--dryrun"], ["--dry_run"], ["--check"], ["--build", BUILD, "--force"], [BUILD]):
            with self.subTest(args=args):
                self.assertStopsBeforeAnyCall(*args, code=2)

    def test_a_flag_missing_its_value_stops_before_any_call(self):
        for args in (["--build"], ["--notes"], ["--build", "--dry-run"]):
            with self.subTest(args=args):
                self.assertStopsBeforeAnyCall(*args, code=2)

    def test_notes_naming_a_missing_file_stop_before_any_call(self):
        for arg in (f"docs/appstore-review-notes-{NEXT_VERSION}9.txt", "no-such-notes.txt", "/nonexistent/notes"):
            with self.subTest(arg=arg):
                self.assertStopsBeforeAnyCall("--notes", arg)

    def test_relative_notes_resolve_against_the_repo_root(self):
        root, elsewhere = tempfile.mkdtemp(), tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        self.addCleanup(shutil.rmtree, elsewhere)
        os.makedirs(os.path.join(root, "docs"))
        with open(os.path.join(root, "docs", "notes.txt"), "w") as f:
            f.write("Hello, reviewer.\n")
        self.sub.ROOT = root
        cwd = os.getcwd()
        os.chdir(elsewhere)              # like the hub-cwd `!` line
        self.addCleanup(os.chdir, cwd)
        self.assertEqual(self.sub._read_notes("docs/notes.txt"), "Hello, reviewer.")
        self.assertEqual(self.sub._read_notes("Log in is not needed"), "Log in is not needed")

    def test_notes_from_a_file_are_sent(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        os.makedirs(os.path.join(root, "docs"))
        with open(os.path.join(root, "docs", "notes.txt"), "w") as f:
            f.write("Hello, reviewer.")
        self.sub.ROOT = root
        fake = FakeSubmitASC()
        self.run_main(fake, "--notes", "docs/notes.txt")
        detail = next(b for m, p, b in fake.writes if p == "/v1/appStoreReviewDetails")
        self.assertEqual(detail["data"]["attributes"]["notes"], "Hello, reviewer.")

    def test_a_clean_submit_attaches_creates_and_submits(self):
        fake = FakeSubmitASC()
        out = self.run_main(fake, "--build", BUILD)
        self.assertEqual([(m, p) for m, p, b in fake.writes],
                         [("PATCH", "/v1/appStoreVersions/v1/relationships/build"),
                          ("POST", "/v1/reviewSubmissions"),
                          ("POST", "/v1/reviewSubmissionItems"),
                          ("PATCH", "/v1/reviewSubmissions/new-sub")])
        self.assertIn("DONE", out)

    def test_a_version_waiting_for_review_needs_resubmit(self):
        fake = FakeSubmitASC(ver_state="WAITING_FOR_REVIEW", subs={"s1": "WAITING_FOR_REVIEW"})
        with self.assertRaises(SystemExit):
            self.run_main(fake, "--notes", "Updated notes")
        self.assertEqual(fake.writes, [])

    def test_an_open_submission_in_review_needs_resubmit(self):
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETING"):
            with self.subTest(state=state):
                fake = FakeSubmitASC(subs={"s1": state})
                with self.assertRaises(SystemExit):
                    self.run_main(fake)
                self.assertEqual(fake.writes, [])

    def test_resubmit_cancels_the_in_review_submission_and_submits_again(self):
        fake = FakeSubmitASC(ver_state="WAITING_FOR_REVIEW", subs={"s1": "WAITING_FOR_REVIEW"})
        out = self.run_main(fake, "--resubmit")
        paths = [p for m, p, b in fake.writes]
        self.assertLess(paths.index("/v1/reviewSubmissions/s1"), paths.index("/v1/reviewSubmissions"))
        self.assertIn("DONE", out)

    def test_a_submission_not_yet_with_apple_is_replaced_without_resubmit(self):
        for state in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
            with self.subTest(state=state):
                fake = FakeSubmitASC(subs={"s1": state})
                self.assertIn("DONE", self.run_main(fake))
                self.assertIn("/v1/reviewSubmissions/s1", [p for m, p, b in fake.writes])

    def test_a_refused_cancel_stops_before_a_new_submission(self):
        fake = FakeSubmitASC(subs={"s1": "READY_FOR_REVIEW"}, cancel_status=409)
        with self.assertRaises(SystemExit):
            self.run_main(fake)
        self.assertNotIn("/v1/reviewSubmissions", [p for m, p, b in fake.writes])

    def test_a_cancel_that_never_lands_stops_before_a_new_submission(self):
        fake = FakeSubmitASC(subs={"s1": "READY_FOR_REVIEW"}, cancel_sticks=False)
        with self.assertRaises(SystemExit):
            self.run_main(fake)
        self.assertNotIn("/v1/reviewSubmissions", [p for m, p, b in fake.writes])

    def test_dry_run_writes_nothing_even_in_review(self):
        fake = FakeSubmitASC(ver_state="WAITING_FOR_REVIEW", subs={"s1": "IN_REVIEW"})
        out = self.run_main(fake, "--dry-run")
        self.assertEqual(fake.writes, [])
        self.assertIn("dry run", out)

    def test_builds_are_looked_up_within_the_version(self):
        sub = self.sub
        seen = []

        def fake(method, path, body=None):
            seen.append(path)
            return 200, {"data": [{"id": "b1", "attributes": {"version": BUILD, "processingState": "VALID"}}]}

        sub.call = fake
        self.assertEqual(sub.valid_build(VERSION, BUILD), ("b1", BUILD))
        self.assertIn(f"filter[preReleaseVersion.version]={VERSION}", seen[0])
        self.assertIn(f"filter[version]={BUILD}", seen[0])

    def test_an_older_versions_build_is_never_attached(self):
        """2.7 on 2026-11-25: the newest VALID build of ANY version (2.6's 14) was attached, and Apple said 409."""
        sub = self.sub

        def fake(method, path, body=None):
            if f"filter[preReleaseVersion.version]={VERSION}" in path:
                return 200, {"data": []}            # 2.7 has no processed build yet
            return 200, {"data": [{"id": "old", "attributes": {"version": OLD_BUILD, "processingState": "VALID"}}]}

        sub.call = fake
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            sub.valid_build(VERSION)


class ReleaseShTests(unittest.TestCase):
    """Only release.sh's parse_mode block runs (cut out between its markers), never the pipeline."""

    def mode(self, *args):
        with open(os.path.join(HERE, "release.sh"), encoding="utf-8") as f:
            text = f.read()
        start, end = "# >>> parse_mode", "# <<< parse_mode"
        self.assertEqual((text.count(start), text.count(end)), (1, 1), "parse_mode markers")
        block = text[text.index(start):text.index(end)]
        r = subprocess.run(["bash", "-c", block + '\nparse_mode "$@"; echo "$MODE"', "release-test", *args],
                           capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
        return r.returncode, r.stdout.strip()

    def test_modes(self):
        self.assertEqual(self.mode(), (0, "submit"))
        self.assertEqual(self.mode("--no-submit"), (0, "no-submit"))
        self.assertEqual(self.mode("--dry-run"), (0, "dry-run"))
        self.assertEqual(self.mode("--check"), (0, "check"))
        self.assertEqual(self.mode("--help"), (0, "help"))
        self.assertEqual(self.mode("-h"), (0, "help"))

    def test_the_safer_mode_wins_in_either_order(self):
        self.assertEqual(self.mode("--dry-run", "--no-submit"), (0, "dry-run"))
        self.assertEqual(self.mode("--no-submit", "--dry-run"), (0, "dry-run"))
        self.assertEqual(self.mode("--check", "--dry-run"), (0, "check"))
        self.assertEqual(self.mode("--no-submit", "--check"), (0, "check"))

    def test_an_unknown_argument_is_refused(self):
        for arg in ("--dryrun", "--nosubmit", "check", "--force"):
            with self.subTest(arg=arg):
                self.assertEqual(self.mode(arg)[0], 2)

    def test_preflight_runs_before_anything_is_built(self):
        with open(os.path.join(HERE, "release.sh"), encoding="utf-8") as f:
            text = f.read()
        body = text[text.index("# <<< parse_mode"):]
        pre = body.index("scripts/asc_preflight.py")
        for later in ("xcodegen generate", "asc_new_version.py", "xcodebuild", "altool", "asc_submit.py --build"):
            self.assertLess(pre, body.index(later), later)
        self.assertLess(body.index('"$MODE" == check'), body.index("xcodegen generate"))


# --- asc_preflight -----------------------------------------------------------------------------

ANSWERED = {  # a fully answered declaration (ASC's 2026 attribute set), plus the optional nulls
    "advertising": False, "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE",
    "gambling": False, "gamblingSimulated": "NONE", "gunsOrOtherWeapons": "NONE",
    "healthOrWellnessTopics": False, "lootBox": False, "medicalOrTreatmentInformation": "NONE",
    "messagingAndChat": False, "parentalControls": False, "profanityOrCrudeHumor": "NONE",
    "ageAssurance": False, "sexualContentGraphicAndNudity": "NONE", "sexualContentOrNudity": "NONE",
    "horrorOrFearThemes": "NONE", "matureOrSuggestiveThemes": "NONE", "unrestrictedWebAccess": False,
    "userGeneratedContent": False, "violenceCartoonOrFantasy": "NONE", "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "socialMedia": False, "datingAndRelationships": False, "sharedLocation": False,
    # optional, null on a normal app
    "socialMediaAgeRestricted": None, "kidsAgeBand": None, "developerAgeRatingInfoUrl": None,
    "ageRatingOverride": None, "ageRatingOverrideV2": None, "koreaAgeRatingOverride": None,
    "gamblingAndContests": None, "seventeenPlus": None, "gracRatingClassificationNumber": None,
}


class FakePreflightASC:
    """App Store Connect for asc_preflight: versions, uploaded builds, appInfos with age ratings, and the
    answer to the agreement probe. Records every call."""

    def __init__(self, versions=((VERSION, "PREPARE_FOR_SUBMISSION"), (OLD_VERSION, "READY_FOR_SALE")),
                 uploaded=((OLD_VERSION, OLD_BUILD),), infos=None, probe=(200, None)):
        self.versions = list(versions)                  # [(versionString, state)], newest first
        self.uploaded = set(uploaded)                   # {(versionString, build)}
        self.infos = infos if infos is not None else [("info-new", "PREPARE_FOR_SUBMISSION", dict(ANSWERED)),
                                                      ("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED))]
        self.probe = probe
        self.calls = []

    @property
    def writes(self):
        return [(m, p, b) for m, p, b in self.calls if m != "GET"]

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET" and "/appStoreVersions?" in path:
            return 200, {"data": [{"id": f"v-{v}", "attributes": {"versionString": v, "appStoreState": st}}
                                  for v, st in self.versions]}
        if method == "GET" and path.startswith("/v1/builds?"):
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
            key = (q["filter[preReleaseVersion.version]"][0], q["filter[version]"][0])
            return 200, {"data": [{"id": "b", "attributes": {"version": key[1], "processingState": "VALID"}}]
                         if key in self.uploaded else []}
        if method == "GET" and "/appInfos?" in path:
            return 200, {"data": [{"id": i, "attributes": {"state": st}} for i, st, _ in self.infos]}
        if method == "GET" and path.endswith("/ageRatingDeclaration"):
            info = path.split("/")[3]
            attrs = next(a for i, _, a in self.infos if i == info)
            return 200, {"data": {"id": f"decl-{info}", "type": "ageRatingDeclarations", "attributes": attrs}}
        if method == "PATCH" and path.startswith("/v1/ageRatingDeclarations/"):
            status, payload = self.probe
            return status, payload if payload is not None else {"data": body["data"]}
        raise AssertionError(f"unexpected {method} {path}")


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="asc-preflight-test-")
        self.addCleanup(shutil.rmtree, self.tmp)
        self.pf = load("asc_preflight")
        self.pf.ROOT = self.tmp
        self.pf.PROJECT_YML = os.path.join(self.tmp, "project.yml")
        self.pf.METADATA = os.path.join(self.tmp, "fastlane", "metadata")
        self.pf.KEY_DIR = os.path.join(self.tmp, "keys")
        os.makedirs(self.pf.KEY_DIR)
        for key in ("FNJQ483TF7", "J6LV34D5S8"):
            open(os.path.join(self.pf.KEY_DIR, f"AuthKey_{key}.p8"), "w").close()   # never read: ASC is faked
        self.pf.asc.KEY_PATH = os.path.join(self.pf.KEY_DIR, "AuthKey_J6LV34D5S8.p8")
        self.project(VERSION, BUILD)
        for locale in ("cs", "en-US"):
            self.write(f"fastlane/metadata/{locale}/release_notes.txt", "Fix.")
        self.write(self.pf.REVIEW_NOTES.format(version=VERSION), "Hello, reviewer.")
        patcher = mock.patch.dict(os.environ)          # restored after each test
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in filter(None, (self.pf.SIGNING_KEY_ENV, self.pf.BUILD_ENV,
                                 self.pf.SIGNING_OPT_OUT and self.pf.SIGNING_OPT_OUT[0])):
            os.environ.pop(var, None)

    def write(self, rel, text):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def project(self, version, build):
        self.write("project.yml", f'settings:\n  base:\n    MARKETING_VERSION: "{version}"\n'
                                  f'    CURRENT_PROJECT_VERSION: "{build}"\n')

    def run_main(self, fake, *args):
        self.pf.asc.call = fake
        argv, sys.argv = sys.argv, ["asc_preflight.py", *args]
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as stop:
                self.pf.main()
        finally:
            sys.argv = argv
        return stop.exception.code, out.getvalue()

    def line(self, out, check):
        return next((l for l in out.splitlines() if l[2:].startswith(check)), "")

    def test_the_happy_path_passes_with_one_write(self):
        fake = FakePreflightASC()
        code, out = self.run_main(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("0 fatal", out)
        self.assertNotIn("✗", out)
        self.assertEqual(len(fake.writes), 1)

    def test_help_prints_usage_and_makes_no_call(self):
        fake = FakePreflightASC()
        self.pf.asc.call = fake
        argv, sys.argv = sys.argv, ["asc_preflight.py", "--help"]
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                self.pf.main()
        finally:
            sys.argv = argv
        self.assertIn("Usage:", out.getvalue())
        self.assertEqual(fake.calls, [])

    def test_an_unknown_flag_exits_2_before_any_call(self):
        for args in (["--dry-run"], ["--chek"], ["--build"], ["--build", "--help"], [BUILD]):
            with self.subTest(args=args):
                fake = FakePreflightASC()
                code, _ = self.run_main(fake, *args)
                self.assertEqual((code, fake.calls), (2, []))

    def test_a_missing_agreement_is_fatal(self):
        fake = FakePreflightASC(probe=(403, {"errors": [{"status": "403", "code": self.pf.AGREEMENT_CODE,
                                                         "title": "A required agreement is missing or has expired."}]}))
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("✗", self.line(out, "agreements"))
        self.assertIn("accept the updated agreement", self.line(out, "agreements"))

    def test_the_probe_sends_exactly_the_current_value_back(self):
        for value in (False, True):
            with self.subTest(advertising=value):
                answers = dict(ANSWERED, advertising=value)
                fake = FakePreflightASC(infos=[("info-new", "PREPARE_FOR_SUBMISSION", answers)])
                self.assertEqual(self.run_main(fake)[0], 0)
                [(method, path, body)] = fake.writes
                self.assertEqual((method, path), ("PATCH", "/v1/ageRatingDeclarations/decl-info-new"))
                self.assertEqual(body, {"data": {"type": "ageRatingDeclarations", "id": "decl-info-new",
                                                 "attributes": {"advertising": value}}})

    def test_the_probe_skips_a_null_answer(self):
        answers = dict(ANSWERED, advertising=None)
        fake = FakePreflightASC(infos=[("info-new", "PREPARE_FOR_SUBMISSION", answers)])
        self.run_main(fake)
        [(_, _, body)] = fake.writes
        self.assertEqual(body["data"]["attributes"], {"gambling": False})

    def test_the_probe_prefers_the_editable_appinfo_and_never_touches_one_with_apple(self):
        fake = FakePreflightASC(infos=[("info-review", "WAITING_FOR_REVIEW", dict(ANSWERED)),
                                       ("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED)),
                                       ("info-new", "PREPARE_FOR_SUBMISSION", dict(ANSWERED))])
        self.run_main(fake)
        self.assertEqual([p for m, p, b in fake.writes], ["/v1/ageRatingDeclarations/decl-info-new"])
        fake = FakePreflightASC(infos=[("info-review", "WAITING_FOR_REVIEW", dict(ANSWERED)),
                                       ("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED))])
        self.run_main(fake)
        self.assertEqual([p for m, p, b in fake.writes], ["/v1/ageRatingDeclarations/decl-info-live"])
        fake = FakePreflightASC(infos=[("info-review", "WAITING_FOR_REVIEW", dict(ANSWERED))])
        _, out = self.run_main(fake)
        self.assertEqual(fake.writes, [])
        self.assertIn("!", self.line(out, "agreements"))

    def test_any_other_probe_failure_is_fatal(self):
        for status, code in ((401, "NOT_AUTHORIZED"), (403, "FORBIDDEN_ERROR"), (409, "ENTITY_ERROR"),
                             (500, "UNEXPECTED_ERROR")):
            with self.subTest(status=status):
                fake = FakePreflightASC(probe=(status, {"errors": [{"code": code, "detail": "no"}]}))
                rc, out = self.run_main(fake)
                self.assertEqual(rc, 1)
                self.assertIn(code, self.line(out, "agreements"))

    def test_a_409_from_the_live_appinfo_is_only_a_warning(self):
        fake = FakePreflightASC(infos=[("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED))],
                                probe=(409, {"errors": [{"code": "STATE_ERROR", "detail": "not editable"}]}))
        rc, out = self.run_main(fake)
        self.assertEqual(rc, 0, out)
        self.assertIn("!", self.line(out, "agreements"))

    def test_unanswered_new_questions_are_fatal(self):
        answers = dict(ANSWERED, socialMedia=None, datingAndRelationships=None, sharedLocation=None)
        fake = FakePreflightASC(infos=[("info-new", "PREPARE_FOR_SUBMISSION", answers),
                                       ("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED))])
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        line = self.line(out, "age rating")
        self.assertIn("✗", line)
        for name in ("socialMedia", "datingAndRelationships", "sharedLocation"):
            self.assertIn(name, line)
        self.assertIn("App Information -> Age Rating", line)
        self.assertTrue(all(b["data"]["attributes"] == {"advertising": False} for m, p, b in fake.writes))

    def test_every_appinfo_is_checked(self):
        fake = FakePreflightASC(infos=[("info-new", "PREPARE_FOR_SUBMISSION", dict(ANSWERED)),
                                       ("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED, socialMedia=None))])
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("READY_FOR_DISTRIBUTION", self.line(out, "age rating"))

    def test_optional_nulls_are_ignored(self):
        fake = FakePreflightASC()           # ANSWERED carries every optional attribute as null
        code, out = self.run_main(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("✓", self.line(out, "age rating"))

    def test_social_media_age_restriction_is_required_once_social_media_is_yes(self):
        fake = FakePreflightASC(infos=[("info-new", "PREPARE_FOR_SUBMISSION", dict(ANSWERED, socialMedia=True))])
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("socialMediaAgeRestricted", self.line(out, "age rating"))

    def test_a_missing_signing_key_is_fatal(self):
        os.remove(os.path.join(self.pf.KEY_DIR, "AuthKey_FNJQ483TF7.p8"))
        code, out = self.run_main(FakePreflightASC())
        self.assertEqual(code, 1)
        self.assertIn("✗", self.line(out, "signing key"))
        self.assertIn("FNJQ483TF7", self.line(out, "signing key"))

    def test_the_signing_key_follows_release_shs_variable(self):
        os.environ[self.pf.SIGNING_KEY_ENV] = "OTHERKEY01"
        code, out = self.run_main(FakePreflightASC())
        self.assertEqual(code, 1)
        self.assertIn("AuthKey_OTHERKEY01.p8", self.line(out, "signing key"))

    def test_a_missing_api_key_is_fatal_and_nothing_is_called(self):
        os.remove(self.pf.asc.KEY_PATH)
        fake = FakePreflightASC()
        code, out = self.run_main(fake)
        self.assertEqual((code, fake.calls), (1, []))
        self.assertIn("✗", self.line(out, "api key"))

    def test_a_version_already_with_apple_is_not_bumped(self):
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE"):
            with self.subTest(state=state):
                fake = FakePreflightASC(versions=[(VERSION, state), (OLD_VERSION, "READY_FOR_SALE")])
                code, out = self.run_main(fake)
                self.assertEqual(code, 1)
                self.assertIn("bump", self.line(out, "version"))

    def test_a_new_version_while_another_is_in_flight_is_fatal(self):
        self.project(NEXT_VERSION, "1")
        self.write(self.pf.REVIEW_NOTES.format(version=NEXT_VERSION), "Hi.")
        fake = FakePreflightASC(versions=[(VERSION, "WAITING_FOR_REVIEW"), (OLD_VERSION, "READY_FOR_SALE")])
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("one version in flight", self.line(out, "version"))

    def test_a_new_version_after_a_release_passes(self):
        self.project(NEXT_VERSION, "1")
        self.write(self.pf.REVIEW_NOTES.format(version=NEXT_VERSION), "Hi.")
        fake = FakePreflightASC(versions=[(VERSION, "READY_FOR_SALE"), (OLD_VERSION, "REPLACED_WITH_NEW_VERSION")],
                                infos=[("info-live", "READY_FOR_DISTRIBUTION", dict(ANSWERED))])
        code, out = self.run_main(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("will be created", self.line(out, "version"))

    def test_a_version_older_than_the_live_one_is_fatal(self):
        self.project("2.5", "1")
        fake = FakePreflightASC(versions=[(VERSION, "READY_FOR_SALE")])
        code, out = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("✗", self.line(out, "version"))

    def test_a_build_already_uploaded_for_the_version_is_fatal(self):
        fake = FakePreflightASC(uploaded={(VERSION, BUILD)})
        code, out = self.run_main(fake, "--build", BUILD)
        self.assertEqual(code, 1)
        self.assertIn("already uploaded", self.line(out, "build"))

    def test_the_build_lookup_is_within_the_version(self):
        fake = FakePreflightASC(uploaded={(OLD_VERSION, BUILD)})     # same number, another version
        code, out = self.run_main(fake, "--build", BUILD)
        self.assertEqual(code, 0, out)
        self.assertIn("not uploaded", self.line(out, "build"))

    def test_empty_whats_new_is_fatal(self):
        self.write("fastlane/metadata/en-US/release_notes.txt", "  \n")
        os.remove(os.path.join(self.tmp, "fastlane/metadata/cs/release_notes.txt"))
        code, out = self.run_main(FakePreflightASC())
        self.assertEqual(code, 1)
        self.assertIn("cs (no file), en-US (empty)", self.line(out, "what's new"))

    def test_whats_new_is_not_needed_before_the_first_release(self):
        os.remove(os.path.join(self.tmp, "fastlane/metadata/cs/release_notes.txt"))
        fake = FakePreflightASC(versions=[(VERSION, "PREPARE_FOR_SUBMISSION")])
        code, out = self.run_main(fake)
        self.assertEqual(code, 0, out)

    def test_missing_review_notes_are_only_a_warning(self):
        os.remove(os.path.join(self.tmp, self.pf.REVIEW_NOTES.format(version=VERSION)))
        code, out = self.run_main(FakePreflightASC())
        self.assertEqual(code, 0, out)
        self.assertIn("!", self.line(out, "review notes"))
        self.assertIn("1 warning", out)

    def test_every_blocker_is_reported_at_once(self):
        os.remove(os.path.join(self.pf.KEY_DIR, "AuthKey_FNJQ483TF7.p8"))
        self.write("fastlane/metadata/cs/release_notes.txt", "")
        fake = FakePreflightASC(versions=[(VERSION, "WAITING_FOR_REVIEW"), (OLD_VERSION, "READY_FOR_SALE")],
                                uploaded={(VERSION, BUILD)},
                                infos=[("info-new", "PREPARE_FOR_SUBMISSION", dict(ANSWERED, socialMedia=None))],
                                probe=(403, {"errors": [{"code": self.pf.AGREEMENT_CODE}]}))
        code, out = self.run_main(fake, "--build", BUILD)
        self.assertEqual(code, 1)
        for check in ("signing key", "version", "build", "age rating", "agreements", "what's new"):
            self.assertIn("✗", self.line(out, check), check)
        self.assertIn("6 fatal", out)

    def test_an_unreachable_store_is_one_fatal_line(self):
        def offline(method, path, body=None):
            raise OSError("nodename nor servname provided")
        code, out = self.run_main(offline)
        self.assertEqual(code, 1)
        self.assertIn("unreachable", self.line(out, "connect"))
        self.assertNotIn("Traceback", out)


if __name__ == "__main__":
    unittest.main()
