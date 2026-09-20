from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'


class RowDomainContractTests(unittest.TestCase):
    """Static source-contract checks only. These are NOT iOS build or
    simulator evidence — real acceptance runs in the pinned macOS CI job."""

    def test_domain_and_persistence_sources_exist_and_are_wired(self):
        app_sources = APP.rglob('*.swift')
        names = sorted(p.name for p in app_sources)
        for expected in ('RowArithmetic.swift', 'RowModels.swift', 'RowReducer.swift',
                         'RowRecords.swift', 'RowStoreFactory.swift', 'RowRepository.swift'):
            self.assertIn(expected, names)
        test_names = sorted(p.name for p in (ROOT / 'RowCompanionTests').glob('*.swift'))
        for expected in ('RowArithmeticTests.swift', 'RowReducerTests.swift', 'RowRepositoryTests.swift'):
            self.assertIn(expected, test_names)
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for source in ('RowArithmetic.swift', 'RowModels.swift', 'RowReducer.swift',
                       'RowRecords.swift', 'RowStoreFactory.swift', 'RowRepository.swift',
                       'RowArithmeticTests.swift', 'RowReducerTests.swift', 'RowRepositoryTests.swift'):
            self.assertIn('path = ' + source, project)

    def test_domain_layer_avoids_ui_and_persistence_imports(self):
        for path in (APP / 'Domain').glob('*.swift'):
            text = path.read_text()
            self.assertNotIn('import SwiftUI', text, path.name)
            self.assertNotIn('import SwiftData', text, path.name)
            self.assertNotIn('import PDFKit', text, path.name)

    def test_repeat_arithmetic_bounds_match_plan(self):
        text = (APP / 'Domain' / 'RowArithmetic.swift').read_text()
        self.assertIn('maximumCompletedRows = 1_000_000', text)
        self.assertIn('maximumRepeatLength = 10_000', text)
        self.assertIn('(n % l) + 1', text)
        self.assertIn('n / l', text)

    def test_labels_distinguish_completed_from_next(self):
        text = (APP / 'Domain' / 'RowArithmetic.swift').read_text()
        self.assertIn('Completed rows', text)
        self.assertIn('Next repeat row', text)

    def test_persistence_pins_cloudkit_disabled_storage(self):
        text = (APP / 'Persistence' / 'RowStoreFactory.swift').read_text()
        self.assertIn('cloudKitDatabase: .none', text)
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('CloudKit', project)

    def test_repository_rolls_back_on_save_fault(self):
        text = (APP / 'Persistence' / 'RowRepository.swift').read_text()
        self.assertIn('context.rollback()', text)
        self.assertIn('testSaveFault', text)


if __name__ == '__main__':
    unittest.main()
