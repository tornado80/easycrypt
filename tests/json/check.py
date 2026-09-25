#! /usr/bin/env python3
# -------------------------------------------------------------------- #
# Tests for `easycrypt cli -json` (see doc/json-output.md).
#
#   python3 tests/json/check.py [--bin ./ec.native]
#
# Every test feeds a script to `cli -json` on stdin and checks the answers:
# exactly one JSON line on stdout per sentence, and nothing else.
# -------------------------------------------------------------------- #

import json, os, subprocess, sys, tempfile, unittest

BIN = os.path.abspath(
    os.environ.get('EC_BIN') or
    os.path.join(os.path.dirname(__file__), '..', '..', 'ec.native'))

# EasyCrypt looks for `easycrypt.project` in the working directory, and the
# one at the root of the source tree pins provers that may not be installed:
# run from a neutral directory.
CWD = tempfile.gettempdir()


def run(script, extra=()):
    """Run [script] (a list of sentences); return the parsed answers."""
    proc = subprocess.run(
        [BIN, 'cli', '-json', *extra],
        input='\n'.join(script) + '\n', text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, cwd=CWD)
    lines = proc.stdout.split('\n')
    assert lines[-1] == '', 'stdout must end with a newline'
    answers = []
    for line in lines[:-1]:
        assert line.strip() != '', 'empty line on stdout'
        answers.append(json.loads(line))
    return answers


def goals(answer):
    return answer['proof']['goals']


PRHL = [
    'require import AllCore Distr DBool.',
    'module M = { proc f(a : int) : bool = { var b : bool;'
    ' if (a = 0) { b <$ dbool; } else { if (a = 1) { b <- true; }'
    ' else { b <- false; } } return b; } }.',
    'module N = { proc f(a : int) : bool = { var b : bool;'
    ' if (a = 0) { b <$ dbool; } else { if (a = 1) { b <- true; }'
    ' else { b <- false; } } return b; } }.',
    'equiv e : M.f ~ N.f : ={a} ==> ={res}.',
    'proof.',
    'proc; inline *.',
]


class Framing(unittest.TestCase):
    def test_one_line_per_sentence(self):
        script = ['require import AllCore.', 'lemma t : true.', 'proof.',
                  'trivial.', 'qed.', 'print bool.', 'exit.']
        answers = run(script)
        self.assertEqual(len(answers), len(script))
        for a in answers:
            self.assertEqual(a['version'], 'domino-json/1')
            self.assertIn(a['status'], ('ok', 'error', 'interrupted'))
        self.assertEqual([a['state'] for a in answers],
                         [1, 2, 3, 4, 5, 6, 6])

    def test_print_goes_to_messages(self):
        answers = run(['require import AllCore.', 'print bool.'])
        texts = [m['text'] for m in answers[1]['messages']]
        self.assertTrue(any('bool' in t for t in texts), texts)

    def test_eof_is_an_exit(self):
        self.assertEqual(len(run(['require import AllCore.'])), 2)

    def test_no_proof(self):
        answers = run(['require import AllCore.'])
        self.assertIsNone(answers[0]['proof'])


class Errors(unittest.TestCase):
    def test_error_with_location(self):
        answers = run(['require import AllCore.', 'lemma t : true.',
                       'proof.', 'apply nonexistent.', 'trivial.'])
        bad = answers[3]
        self.assertEqual(bad['status'], 'error')
        self.assertIn('msg', bad['error'])
        loc = bad['error']['loc']
        self.assertEqual(loc['start'], 0)
        self.assertGreater(loc['end'], loc['start'])
        # A failure changes nothing: same depth, same goals, and the
        # session goes on.
        self.assertEqual(bad['state'], answers[2]['state'])
        self.assertEqual(goals(bad), goals(answers[2]))
        self.assertEqual(answers[4]['status'], 'ok')
        self.assertEqual(goals(answers[4]), [])

    def test_syntax_error(self):
        answers = run(['require import AllCore.', 'lemma lemma lemma.',
                       'lemma t : true.'])
        self.assertEqual(answers[1]['status'], 'error')
        self.assertEqual(answers[2]['status'], 'ok')


class Goals(unittest.TestCase):
    def test_forall_binders(self):
        answers = run(['require import AllCore.',
                       'lemma t (x : int) : forall (y : int) (z : bool), x + y = y + x.',
                       'proof.'])
        g, = goals(answers[2])
        self.assertEqual([h['name'] for h in g['hyps']], ['x'])
        self.assertEqual(g['hyps'][0]['kind'], 'var')
        self.assertEqual(g['hyps'][0]['type']['pp'], 'int')
        c = g['concl']
        self.assertEqual(c['kind'], 'quant')
        self.assertEqual(c['quantifier'], 'forall')
        self.assertEqual([(b['name'], b['type']['pp']) for b in c['binders']],
                         [('y', 'int'), ('z', 'bool')])
        self.assertEqual(c['body']['kind'], 'app')
        self.assertEqual(c['body']['op'], 'Top.Pervasive.=')
        # Two binders with the same name stay distinct.
        answers = run(['require import AllCore.',
                       'lemma t (x : int) : forall (x : int), x = x.',
                       'proof.', 'move=> x0.'])
        outer = goals(answers[2])[0]
        binder = outer['concl']['binders'][0]
        self.assertEqual(outer['hyps'][0]['ident']['name'], 'x')
        self.assertEqual(binder['ident']['name'], 'x')
        self.assertNotEqual(outer['hyps'][0]['ident']['tag'],
                            binder['ident']['tag'])
        self.assertNotEqual(outer['hyps'][0]['name'], binder['name'])

    def test_several_goals_with_their_own_hyps(self):
        answers = run(['require import AllCore.',
                       'lemma t (a : int) : a = a.', 'proof.',
                       'case (a = 0) => h.'])
        gs = goals(answers[3])
        self.assertEqual(len(gs), 2)
        self.assertEqual([g['id'] for g in gs], [1, 2])
        for g in gs:
            self.assertEqual([h['name'] for h in g['hyps']], ['a', 'h'])
            self.assertEqual(g['hyps'][1]['kind'], 'hyp')
        self.assertEqual(gs[0]['hyps'][1]['form']['pp'], 'a = 0')
        self.assertEqual(gs[1]['hyps'][1]['form']['pp'], 'a <> 0')

    def test_undo_restores_the_exact_goals(self):
        answers = run(['require import AllCore.',
                       'lemma t (x : int) : forall y, x + y = y + x.',
                       'proof.', 'move=> y.', 'undo 3.'])
        self.assertNotEqual(answers[3], answers[2])
        self.assertEqual(answers[4], answers[2])

    def test_goal_text(self):
        answers = run(['require import AllCore.', 'lemma t (x : int) : x = x.',
                       'proof.'])
        text = goals(answers[2])[0]['text']
        self.assertIn('x: int', text)
        self.assertIn('x = x', text)


class Programs(unittest.TestCase):
    def setUp(self):
        self.answers = run(PRHL)

    def test_prhl_after_proc_inline(self):
        g, = goals(self.answers[-1])
        c = g['concl']
        self.assertEqual(c['kind'], 'equivS')
        for side, mem in (('left', '&1'), ('right', '&2')):
            s = c[side]
            self.assertEqual(s['mem'], mem)
            self.assertEqual([l['name'] for l in s['memtype']['locals']],
                             ['a', 'b'])
            top = s['stmt']
            self.assertEqual([i['kind'] for i in top], ['if'])
            cond = top[0]['cond']
            self.assertEqual(cond['pp'], 'a = 0')
            self.assertEqual([i['kind'] for i in top[0]['then']], ['rnd'])
            rnd = top[0]['then'][0]
            self.assertEqual(rnd['lvalue']['vars'][0]['name'], 'b')
            self.assertEqual(rnd['expr']['pp'], '{0,1}')
            inner = top[0]['else']
            self.assertEqual([i['kind'] for i in inner], ['if'])
            self.assertEqual([i['kind'] for i in inner[0]['then']], ['asgn'])
            self.assertEqual(inner[0]['then'][0]['pp'], 'b <- true;')
            self.assertEqual(inner[0]['else'][0]['pp'], 'b <- false;')
            self.assertIn('if (a = 0)', s['stmt_pp'])
        self.assertEqual(c['pre']['kind'], 'app')
        self.assertEqual(c['post']['pp'], 'b{1} = b{2}')
        # program variables are printed with their side in pre/post
        self.assertEqual(c['pre']['pp'], 'a{1} = a{2}')

    def test_operator_paths(self):
        g, = goals(self.answers[-1])
        pre = g['concl']['pre']
        self.assertEqual(pre['op'], 'Top.Pervasive.=')
        self.assertEqual(pre['args'][0]['kind'], 'pvar')
        self.assertEqual(pre['args'][0]['mem'], '&1')
        self.assertEqual(pre['args'][0]['name'], 'a')

    def test_procedure_level_judgement(self):
        answers = run(PRHL[:4] + ['proof.'])
        c = goals(answers[-1])[0]['concl']
        self.assertEqual(c['kind'], 'equivF')
        self.assertEqual(c['left']['proc']['top'], 'Top.M')
        self.assertEqual(c['left']['proc']['name'], 'f')
        self.assertEqual(c['right']['proc']['pp'], 'N.f')
        self.assertEqual(c['pre']['pp'], 'arg{1} = arg{2}')

    def test_user_operator_is_an_application(self):
        script = PRHL[:3] + [
            'op inv (x y : bool) = x = y.',
            'equiv e : M.f ~ N.f : ={a} ==> inv res{1} res{2} /\\ ={res}.',
            'proof.', 'proc; inline *.']
        answers = run(script)
        post = goals(answers[-1])[0]['concl']['post']
        self.assertEqual(post['kind'], 'app')
        self.assertEqual(post['args'][0]['op'], 'Top.inv')
        self.assertEqual(post['args'][0]['args'][0]['kind'], 'pvar')
        self.assertEqual(post['args'][0]['args'][0]['mem'], '&1')

    def test_hoare(self):
        answers = run(PRHL[:2] + [
            'lemma h : hoare[M.f : true ==> true].', 'proof.', 'proc.'])
        c = goals(answers[-1])[0]['concl']
        self.assertEqual(c['kind'], 'hoareS')
        self.assertEqual(c['program']['stmt'][0]['kind'], 'if')
        self.assertEqual(c['post']['pp'], 'true')
        self.assertEqual(c['exn'], [])


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == '--bin':
        BIN = os.path.abspath(sys.argv[2])
        del sys.argv[1:3]
    unittest.main()
