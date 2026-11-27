package pl.seniordeveloper.gradle

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource

class QuarantineRulesTest {
	@ParameterizedTest
	@ValueSource(
		strings = [
			"@Tag(\"quarantine\")",
			"@Tag(PlatformTestTags.QUARANTINE)",
			"@Tag(QUARANTINE)",
			"@Tag(pl.seniordeveloper.platform.test.PlatformTestTags.QUARANTINE)",
			"@Tag(value = \"quarantine\")",
			"@Tag( value=PlatformTestTags.QUARANTINE )",
			"@Tags({@Tag(\"slow\"), @Tag(QUARANTINE)})",
		],
	)
	fun `every way of writing the quarantine tag needs an issue and a date`(tag: String) {
		val entries = QuarantineRules.scan(listOf("FlakyTest.java" to "class FlakyTest {\n  // flaky on CI\n  $tag\n  void flaky() {}\n}"))

		assertEquals(listOf(QuarantineEntry("FlakyTest.java", 3, null, null)), entries)
	}

	@Test
	fun `a tag that only looks like quarantine is not one`() {
		val text = "@Tag(\"quarantine-free\")\n@Tag(NOT_QUARANTINE_X)\n@Tag(\"slow\")\nclass FastTest {}"

		assertEquals(emptyList<QuarantineEntry>(), QuarantineRules.scan(listOf("FastTest.java" to text)))
	}

	@Test
	fun `a meta-annotation carrying the tag quarantines each test that uses it`() {
		val annotation =
			"""
			@Target(ElementType.METHOD)
			@Retention(RetentionPolicy.RUNTIME)
			@Tag("quarantine")
			public @interface Flaky {}
			""".trimIndent()
		val test =
			"""
			class FlakyTest {
			  // quarantine: https://github.com/example/library/issues/1 until 2099-12-31
			  @Flaky
			  void tracked() {}

			  @Flaky
			  void untracked() {}
			}
			""".trimIndent()

		val entries = QuarantineRules.scan(listOf("Flaky.java" to annotation, "FlakyTest.java" to test))

		assertEquals(
			listOf(
				QuarantineEntry("FlakyTest.java", 3, "https://github.com/example/library/issues/1", java.time.LocalDate.parse("2099-12-31")),
				QuarantineEntry("FlakyTest.java", 6, null, null),
			),
			entries,
		)
	}

	@Test
	fun `a Kotlin meta-annotation and a meta-annotation of a meta-annotation are followed too`() {
		val annotation = "@Tag(QUARANTINE)\nannotation class Flaky\n\n@Flaky\n@Retention(AnnotationRetention.RUNTIME)\nannotation class VeryFlaky"
		val test = "class FlakyTest {\n  @VeryFlaky\n  fun flaky() {}\n}"

		val entries = QuarantineRules.scan(listOf("Flaky.kt" to annotation, "FlakyTest.kt" to test))

		assertEquals(listOf(QuarantineEntry("FlakyTest.kt", 2, null, null)), entries)
	}
}
