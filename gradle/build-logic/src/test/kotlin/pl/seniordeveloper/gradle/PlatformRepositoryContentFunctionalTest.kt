package pl.seniordeveloper.gradle

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Path

/**
 * Współrzędne Platform (`pl.seniordeveloper`) przychodzą wyłącznie z repozytoriów Platform: z GitHub Packages albo
 * z jawnego -PplatformRepository (ADR-0003). Inne repozytorium — Maven Central albo dopisane przez konsumenta, nawet
 * przed repozytoriami Platform — nie może podsunąć ich kopii. Obce repozytorium udaje tu lokalny katalog z podrobionym
 * platform-bom, a prawdziwy leży w -PplatformRepository, więc test nie pyta GitHub Packages.
 */
class PlatformRepositoryContentFunctionalTest {
	@TempDir
	lateinit var directory: Path

	@Test
	fun `Platform coordinates resolve only from the Platform repositories`() {
		val consumer = ConsumerFixture(directory.resolve("consumer"), "java-library")
		val version = System.getProperty("platform.version")
		val imposter = directory.resolve("imposter").toFile()
		pom(imposter, "pl.seniordeveloper", "platform-bom", version, constraint = "org.example:ordinary:2.0.0")
		pom(imposter, "org.example", "ordinary", "2.0.0")
		pom(imposter, "org.example", "ordinary", "1.0.0")
		consumer.file("settings.gradle.kts").appendText(
			"""

			dependencyResolutionManagement {
				repositories {
					val imposter = maven { url = uri("${imposter.toURI()}") }
					remove(imposter)
					addFirst(imposter)
				}
			}
			""".trimIndent() + "\n",
		)
		consumer.appendToBuildScript(
			"""
			dependencies {
				implementation(platform("pl.seniordeveloper:platform-bom:$version"))
				implementation("org.example:ordinary:1.0.0")
			}
			""".trimIndent(),
		)

		val output = consumer.runner("dependencies", "--configuration", "compileClasspath").build().output

		assertTrue(output.contains("pl.seniordeveloper:platform-bom:$version"), "the build must resolve platform-bom:\n$output")
		assertFalse(
			output.contains("org.example:ordinary:1.0.0 -> 2.0.0"),
			"platform-bom must come from the Platform repository, not the imposter:\n$output",
		)
		assertTrue(output.contains("org.example:ordinary:1.0.0"), "other groups still resolve from the other repository:\n$output")
		assertFalse(output.contains("FAILED"), "every dependency must still resolve:\n$output")
	}

	private fun pom(
		repository: File,
		group: String,
		artifact: String,
		version: String,
		constraint: String? = null,
	) {
		File(repository, "${group.replace('.', '/')}/$artifact/$version/$artifact-$version.pom").apply {
			parentFile.mkdirs()
			writeText(
				"""
				<?xml version="1.0" encoding="UTF-8"?>
				<project xmlns="http://maven.apache.org/POM/4.0.0">
				  <modelVersion>4.0.0</modelVersion>
				  <groupId>$group</groupId>
				  <artifactId>$artifact</artifactId>
				  <version>$version</version>
				  <packaging>pom</packaging>
				${constraint?.split(':')?.let { (g, a, v) ->
					"<dependencyManagement><dependencies><dependency><groupId>$g</groupId><artifactId>$a</artifactId><version>$v</version></dependency></dependencies></dependencyManagement>"
				} ?: ""}
				</project>
				""".trimIndent(),
			)
		}
	}
}
