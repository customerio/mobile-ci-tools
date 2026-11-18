import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sdk_team_review as s  # noqa: E402

REPO = "customerio/customerio-ios-fcm"
SHA = "a" * 40
OTHER = "b" * 40


def attestation(**overrides):
    summary = {"v": 1, "reviewed_sha": SHA, "verdict": "pass", "important": 0, "nits": 2,
               "change_safety": "none", "reviewer": "cio-code-review", "reviewer_version": "2.5.0"}
    summary.update(overrides)
    return json.dumps(summary)


def pr(sha=SHA, repo=REPO, state="open", draft=False):
    return {"state": state, "draft": draft, "head": {"sha": sha, "repo": {"full_name": repo}}}


def run(name, run_id, status="completed", conclusion="success"):
    return {"name": name, "id": run_id, "status": status, "conclusion": conclusion}


GREEN = [run("lint", 1), run("test / automated-tests", 2)]
POLICY = {"team": "squad-mobile", "protected_paths": [".github/**", "CODEOWNERS", "*.podspec"],
          "advisory_checks": ["Socket Security: Project Report"], "ignored_checks": ["dismiss"]}


class GlobTests(unittest.TestCase):
    def test_single_star_stays_in_directory(self):
        self.assertTrue(s.glob_to_regex("*.podspec").match("CioFirebaseWrapper.podspec"))
        self.assertFalse(s.glob_to_regex("*.podspec").match("sub/CioFirebaseWrapper.podspec"))

    def test_double_star_crosses_directories(self):
        r = s.glob_to_regex(".github/**")
        self.assertTrue(r.match(".github/workflows/test.yml"))
        self.assertFalse(r.match("Sources/.github.swift"))

    def test_double_star_slash_matches_zero_directories(self):
        r = s.glob_to_regex("**/CODEOWNERS")
        self.assertTrue(r.match("CODEOWNERS"))
        self.assertTrue(r.match("docs/CODEOWNERS"))

    def test_dots_are_literal(self):
        self.assertFalse(s.glob_to_regex(".releaserc.json").match("xreleasercxjson"))

    def test_protected_matches_lists_hits_once(self):
        hits = s.protected_matches(["Sources/A.swift", ".github/x.yml", "CODEOWNERS"], POLICY["protected_paths"])
        self.assertEqual(hits, [".github/x.yml", "CODEOWNERS"])

    def test_renamed_file_counts_old_name(self):
        paths = s.changed_paths([{"filename": "Sources/B.swift", "previous_filename": ".github/old.yml"}])
        self.assertIn(".github/old.yml", paths)


class AttestationTests(unittest.TestCase):
    def test_passing_summary(self):
        self.assertEqual(s.attestation_problems(attestation(), SHA), [])

    def test_invalid_json(self):
        self.assertEqual(s.attestation_problems("not json", SHA), ["The review summary is not valid JSON."])

    def test_empty(self):
        self.assertTrue(s.attestation_problems("", SHA))

    def test_wrong_commit(self):
        self.assertIn("The review summary is for a different commit than the PR head.",
                      s.attestation_problems(attestation(reviewed_sha=OTHER), SHA))

    def test_failed_verdict_and_findings(self):
        problems = s.attestation_problems(attestation(verdict="fail", important=1, change_safety="auth"), SHA)
        self.assertEqual(len(problems), 3)

    def test_unknown_version(self):
        self.assertTrue(s.attestation_problems(attestation(v=2), SHA))


class CiTests(unittest.TestCase):
    def test_all_green(self):
        self.assertEqual(s.ci_problems(GREEN, []), [])

    def test_cancelled_then_rerun_passes(self):
        runs = [run("test", 1, conclusion="cancelled"), run("test", 5)]
        self.assertEqual(s.ci_problems(runs, []), [])

    def test_latest_failure_wins(self):
        runs = [run("test", 1), run("test", 5, conclusion="failure")]
        self.assertEqual(s.ci_problems(runs, []), ["`test` concluded `failure`."])

    def test_pending(self):
        self.assertEqual(s.ci_problems([run("test", 1, status="in_progress", conclusion=None)], []),
                         ["`test` has not finished."])

    def test_advisory_failure_is_ignored(self):
        runs = GREEN + [run("Socket Security: Project Report", 9, conclusion="failure")]
        self.assertEqual(s.ci_problems(runs, [], advisory=["Socket Security: Project Report"]), [])

    def test_ignored_own_check(self):
        runs = GREEN + [run("dismiss", 9, status="in_progress", conclusion=None)]
        self.assertEqual(s.ci_problems(runs, [], ignored=["dismiss"]), [])

    def test_skipped_and_neutral_pass(self):
        runs = [run("a", 1, conclusion="skipped"), run("b", 2, conclusion="neutral")]
        self.assertEqual(s.ci_problems(runs, []), [])

    def test_commit_statuses_latest_wins(self):
        statuses = [
            {"context": "ci/x", "state": "failure", "updated_at": "2026-11-18T10:00:00Z", "id": 1},
            {"context": "ci/x", "state": "success", "updated_at": "2026-11-18T11:00:00Z", "id": 2},
        ]
        self.assertEqual(s.ci_problems(GREEN, statuses), [])

    def test_pending_status(self):
        statuses = [{"context": "ci/x", "state": "pending", "updated_at": "2026-11-18T10:00:00Z", "id": 1}]
        self.assertEqual(s.ci_problems(GREEN, statuses), ["`ci/x` has not finished."])

    def test_no_ci_at_all(self):
        self.assertEqual(s.ci_problems([], []), ["No CI ran on this commit."])

    def test_only_ignored_checks_counts_as_no_ci(self):
        self.assertEqual(s.ci_problems([run("dismiss", 1)], [], ignored=["dismiss"]), ["No CI ran on this commit."])


class EvaluateTests(unittest.TestCase):
    def decide(self, **kw):
        args = dict(pr=pr(), repo=REPO, input_sha=SHA, paths=["Sources/CioFirebaseWrapper.swift"],
                    check_runs=GREEN, statuses=[], attestation=attestation(), policy=POLICY,
                    actor="dev", team_member=True)
        args.update(kw)
        return s.evaluate(**args)

    def test_approves_clean_pr(self):
        self.assertEqual(self.decide(), [])

    def test_team_not_checked_does_not_block(self):
        self.assertEqual(self.decide(team_member=None), [])

    def test_not_in_team(self):
        self.assertEqual(self.decide(team_member=False), ["`dev` is not in the `squad-mobile` team."])

    def test_head_moved(self):
        reasons = self.decide(pr=pr(sha=OTHER))
        self.assertIn("The PR head changed after the review. Run the review again on the new commit.", reasons)
        self.assertIn("The review summary is for a different commit than the PR head.", reasons)

    def test_fork(self):
        self.assertTrue(any("fork" in r for r in self.decide(pr=pr(repo="someone/customerio-ios-fcm"))))

    def test_fork_with_deleted_repo(self):
        p = pr()
        p["head"]["repo"] = None
        self.assertTrue(any("fork" in r for r in self.decide(pr=p)))

    def test_draft_and_closed(self):
        self.assertEqual(len(self.decide(pr=pr(draft=True))), 1)
        self.assertEqual(len(self.decide(pr=pr(state="closed"))), 1)

    def test_protected_paths(self):
        reasons = self.decide(paths=["Sources/A.swift", ".github/workflows/test.yml"])
        self.assertEqual(reasons, ["Changes files that always need a human review: `.github/workflows/test.yml`."])

    def test_always_protected_without_policy(self):
        reasons = self.decide(policy={}, paths=[".github/workflows/x.yml", "Sources/REVIEW.md", "Sources/A.swift"])
        self.assertEqual(reasons, ["Changes files that always need a human review: `.github/workflows/x.yml`, `Sources/REVIEW.md`."])

    def test_protected_list_is_capped(self):
        paths = [f".github/f{i}.yml" for i in range(12)]
        reasons = self.decide(paths=paths)
        self.assertTrue(reasons[0].endswith("and 2 more."))

    def test_red_ci(self):
        self.assertEqual(self.decide(check_runs=[run("test", 1, conclusion="failure")]),
                         ["`test` concluded `failure`."])


class DismissTests(unittest.TestCase):
    BOT = "sdk-team-review[bot]"

    def review(self, review_id, commit, login=BOT, state="APPROVED"):
        return {"id": review_id, "commit_id": commit, "state": state, "user": {"login": login}}

    def test_keeps_current_bot_approval(self):
        self.assertEqual(s.reviews_to_dismiss([self.review(1, SHA)], SHA, self.BOT, False), [])

    def test_dismisses_stale_bot_approval(self):
        self.assertEqual(s.reviews_to_dismiss([self.review(1, OTHER)], SHA, self.BOT, False), [1])

    def test_keeps_human_approval_on_old_commit(self):
        self.assertEqual(s.reviews_to_dismiss([self.review(1, OTHER, login="dev")], SHA, self.BOT, False), [])

    def test_base_change_dismisses_current_bot_approval(self):
        self.assertEqual(s.reviews_to_dismiss([self.review(1, SHA)], SHA, self.BOT, True), [1])

    def test_ignores_already_dismissed(self):
        self.assertEqual(s.reviews_to_dismiss([self.review(1, OTHER, state="DISMISSED")], SHA, self.BOT, False), [])


class RenderTests(unittest.TestCase):
    def test_shadow_would_approve(self):
        body = s.render_comment("shadow", "dev", SHA, [])
        self.assertIn(s.MARKER, body)
        self.assertIn("would approve `aaaaaaa`", body)

    def test_shadow_lists_reasons_and_notes(self):
        body = s.render_comment("shadow", "dev", SHA, ["`test` concluded `failure`."], ["Team membership was not checked in this run."])
        self.assertIn("would not approve", body)
        self.assertIn("- `test` concluded `failure`.", body)
        self.assertIn("_Team membership was not checked in this run._", body)

    def test_enforce_refusal(self):
        self.assertIn("did not approve", s.render_comment("enforce", "dev", SHA, ["x"]))

    def test_approval_body(self):
        body = s.approval_body("dev", SHA, attestation())
        self.assertIn("cio-code-review 2.5.0, 2 nit(s)", body)


if __name__ == "__main__":
    unittest.main()
