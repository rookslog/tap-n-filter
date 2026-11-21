import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('catalog_generator', ROOT / 'tools/generate-effect-catalog.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / 'Config/EffectCatalog.json').read_text())

    def test_deterministic_and_all_generated_files_current(self):
        a = MODULE.generate(self.data)
        self.assertEqual(a, MODULE.generate(copy.deepcopy(self.data)))
        for path, expected in a.items():
            self.assertEqual((ROOT / path).read_text(), expected, path)

    def test_malformed_contracts_refuse(self):
        def duplicate_id(d): d['parameters'][1]['id'] = d['parameters'][0]['id']
        def duplicate_key(d): d['parameters'][1]['key'] = d['parameters'][0]['key']
        def conversion(d): d['parameters'][0]['conversion'] = 'arbitraryScript'
        def missing_preset(d): d['effects'][3]['presets'].pop(0)
        def nonfinite(d): d['parameters'][0]['range'][1] = float('nan')
        def inverted(d): d['parameters'][0]['range'] = [30, 20]
        def wrong_unit(d): d['effects'][0]['knobs'][0]['targets'][0]['units'] = [13]
        def seed(d): d['effects'][0]['profiles']['everyday.v1'][0]['seed'] = 0
        def admitted_seed(d): d['effects'][4]['profiles']['everyday.v1'][4]['seed'] = 0.0001
        def capacity(d): d['maxBindings'] = 2
        def cave(d): d['effects'][3]['presets'][-1]['native'] = 'AVAudioUnitReverbPresetMediumChamber'
        def reserved(d): d['effects'][3]['id'] = 7
        for mutate in [duplicate_id, duplicate_key, conversion, missing_preset, nonfinite, inverted, wrong_unit, seed, admitted_seed, capacity, cave, reserved]:
            with self.subTest(case=mutate.__name__):
                data = copy.deepcopy(self.data)
                mutate(data)
                with self.assertRaises(ValueError): MODULE.generate(data)

    def test_saved_preset_ids_keep_their_named_apple_presets(self):
        # Saved IDs are user data: re-pointing one changes how existing sounds play.
        expected = {
            'deviceColour': {1: 'AVAudioUnitDistortionPresetSpeechRadioTower', 2: 'AVAudioUnitDistortionPresetSpeechGoldenPi'},
            'reverb': {1: 'AVAudioUnitReverbPresetSmallRoom', 2: 'AVAudioUnitReverbPresetMediumRoom',
                       3: 'AVAudioUnitReverbPresetLargeRoom', 4: 'AVAudioUnitReverbPresetLargeHall',
                       5: 'AVAudioUnitReverbPresetCathedral'},
        }
        actual = {e['type']: {p['id']: p['native'] for p in e['presets']} for e in self.data['effects'] if e['presets']}
        self.assertEqual(actual, expected)
        native = (ROOT / 'Sources/FixedRender/EffectCatalogNative.hpp').read_text()
        for presets in expected.values():
            for preset_id, name in presets.items():
                self.assertIn(f'case {preset_id}: return {name};', native)

    def test_real_cli_check_detects_stale_generated_output(self):
        with tempfile.TemporaryDirectory(prefix='effect-catalog-control-') as directory:
            root = Path(directory)
            (root / 'tools').mkdir()
            (root / 'Config').mkdir()
            shutil.copy2(ROOT / 'tools/generate-effect-catalog.py', root / 'tools')
            shutil.copy2(ROOT / 'Config/EffectCatalog.json', root / 'Config')
            command = [sys.executable, str(root / 'tools/generate-effect-catalog.py')]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            path = root / 'Sources/FixedRender/include/EffectCatalog.h'
            path.write_text(path.read_text() + '// deliberately stale\n')
            result = subprocess.run(command + ['--check'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('stale generated output: Sources/FixedRender/include/EffectCatalog.h', result.stderr)


if __name__ == '__main__':
    unittest.main()
