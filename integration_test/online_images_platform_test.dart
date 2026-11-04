import 'package:integration_test/integration_test.dart';
import '../test/online_reader_test.dart' show onlineReaderTests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  onlineReaderTests(platform: true);
}
