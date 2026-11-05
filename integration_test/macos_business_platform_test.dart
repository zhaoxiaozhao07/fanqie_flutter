import 'package:integration_test/integration_test.dart';
import 'book_directory_platform_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  fixture.bookDirectoryPlatformTests(
    platform: 'macOS',
    skip: !const bool.fromEnvironment('FANQIE_LIVE_API'),
  );
}
