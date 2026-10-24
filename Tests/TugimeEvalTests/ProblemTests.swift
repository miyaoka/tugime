import Foundation
import Testing
import TugimeCore
@testable import TugimeEval

@Suite struct ProblemTests {
    @Test func checksFollowTheSourceWording() {
        #expect(Check.oneOf(["青年誌", "成年誌"]).passes("成年誌"))
        #expect(!Check.oneOf(["青年誌"]).passes("青年誌で"))
        #expect(Check.exact("足しました").passes("足しました"))
        #expect(!Check.exact("足しました").passes("足しました。"))
        #expect(Check.contains("誤算").passes("これは嬉しい誤算です"))
        #expect(!Check.contains("誤算").passes("これは嬉しい五三です"))
        #expect(Check.excludes("田中").passes("気心の知れた仲なので"))
        #expect(!Check.excludes("田中").passes("気心の知れた田中なので"))
    }

    @Test func mozcKeepsOnlyCommandsInTheTable() throws {
        let tsv = """
            # label\tkey\tvalue\tcommand
            a\tたしました\t足しました\tConversion Expected
            a\tこれは\t此れ\tConversion Expected 9
            a\tごさん\t誤算\tConversion Match
            a\tでこめ\t凸\tConversion Not Match
            a\tきょう\t今日\tPrediction Expected\textra

            """
        let parsed = try MozcRegression.problems(from: Data(tsv.utf8), file: "t.tsv", set: "mozc-oss")
        #expect(parsed.problems.map(\.id) == ["mozc-oss:2", "mozc-oss:4", "mozc-oss:5"])
        #expect(parsed.problems.map(\.check) == [.exact("足しました"), .contains("誤算"), .excludes("凸")])
        #expect(parsed.problems.allSatisfy { $0.left.isEmpty })
        #expect(parsed.dropped == 2)
    }

    @Test func mozcStopsAtShortRows() {
        #expect(throws: ProblemLoadError.self) {
            try MozcRegression.problems(from: Data("a\tかな\t仮名\n".utf8), file: "t.tsv", set: "mozc-oss")
        }
    }

    @Test func ajimeeUsesIndexAndHiragana() throws {
        // 長音はそのまま残す（テーマ は てえま でなく てーま）
        let json = #"[{"index":"7","context_text":"男性","input":"テーマ、ヴァイオリン・ヶ","expected_output":["テーマ、ヴァイオリン・ヶ"]}]"#
        let problems = try AJIMEE.problems(from: Data(json.utf8))
        #expect(problems == [Problem(id: "ajimee:7", set: "ajimee", kana: "てーま、ゔぁいおりん・ゖ", left: "男性", check: .oneOf(["テーマ、ヴァイオリン・ヶ"]))])
    }

    @Test func modelWithoutEffectIsCaughtOnlyWhenEveryOutputMatches() {
        let problem = Problem(id: "t:1", set: "t", kana: "かな", left: "", check: .exact("仮名"))
        let result = { (output: String) in
            AccuracyRecord.Result(problem: problem, output: output, baselineOutput: "かな", seconds: 0, baselineSeconds: 0)
        }
        let model = ConversionMethod.azooKeyZenzai(weight: URL(fileURLWithPath: "/m.gguf"))
        #expect(AccuracyRun.modelHadNoEffect([result("かな"), result("かな")], target: model))
        #expect(!AccuracyRun.modelHadNoEffect([result("かな"), result("仮名")], target: model))
        // モデルを使わない方式は、基準と一致して当然なので止めない
        #expect(!AccuracyRun.modelHadNoEffect([result("かな")], target: .azooKey))
    }

    @Test func ajimeeStopsWithoutIndex() {
        let json = #"[{"context_text":"","input":"ア","expected_output":["亜"]}]"#
        #expect(throws: ProblemLoadError.self) {
            try AJIMEE.problems(from: Data(json.utf8))
        }
    }
}
