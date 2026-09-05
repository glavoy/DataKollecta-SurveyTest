import 'package:flutter_test/flutter_test.dart';
import 'package:datakollecta/config/app_config.dart';
import 'package:datakollecta/services/app_paths.dart';
import 'package:datakollecta/services/skip_service.dart';
import 'package:datakollecta/models/question.dart';

void main() {
  test('the field app engine is importable and behaves as itself', () {
    // Confirms the path dependency compiles the real services, not a stub.
    expect(AppConfig.storageFolder, 'GiSTX');
    expect(AppPaths.overrideBaseDir, isNull);

    final answers = <String, dynamic>{'sex': '2'};
    final skip = SkipCondition(
      fieldName: 'sex',
      condition: '=',
      response: '2',
      responseType: 'fixed',
      skipToFieldName: 'pregnancy',
    );
    expect(SkipService.evaluateSkips([skip], answers), 'pregnancy');

    // The fail-open contract the whole simulator depends on.
    expect(SkipService.evaluateSkips([skip], <String, dynamic>{}), isNull);
  });
}
