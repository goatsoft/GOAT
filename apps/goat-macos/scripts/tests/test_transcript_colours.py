import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('colours', Path(__file__).parents[1] / 'check-transcript-colours.py')
colours = importlib.util.module_from_spec(spec)
spec.loader.exec_module(colours)


class TranscriptColourTests(unittest.TestCase):
    def check(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'App/Sources/Bleet').mkdir(parents=True)
            (root / 'App/Sources/DesignSystem').mkdir(parents=True)
            (root / 'App/Sources/DesignSystem/CaprineControls.swift').write_text('')
            (root / 'App/Sources/Bleet/Row.swift').write_text(source)
            return colours.validate(root)

    def test_raw_colours_are_rejected(self):
        for line in ('.foregroundStyle(.orange)', 'return .red', 'Color.green', '.shadow(color: .black.opacity(0.3))'):
            with self.subTest(line=line):
                self.assertEqual(len(self.check(line)), 1)

    def test_tokens_comments_and_lookalikes_are_accepted(self):
        source = '\n'.join([
            '.foregroundStyle(Caprine.Semantic.warning)',
            'text.trimmingCharacters(in: .whitespacesAndNewlines)',
            '// .orange is not allowed here',
            'model.theme.tokens.tint',
            'case .red: break',
        ])
        self.assertEqual(self.check(source), [])

    def test_the_repository_is_clean(self):
        self.assertEqual(colours.validate(), [])


if __name__ == '__main__':
    unittest.main()
