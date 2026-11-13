import Foundation
import XCTest
@testable import LinvellCore

final class SilicaSyntaxTests: XCTestCase {
    func testEverySilicaLanguageRecognizesItsOwnSyntax() {
        let samples: [(String,String,String,SourceTokenKind)] = [
            ("sample.swift","@MainActor func go() {}","@MainActor",.attribute),
            ("sample.js","const value = compute(1);","compute",.function),
            ("sample.ts","interface Item { value: string }","interface",.keyword),
            ("sample.json","{\"item\": 42}","\"item\"",.property),
            ("sample.py","@decorator\ndef example(): pass","@decorator",.attribute),
            ("sample.rb","@amount = 4","@amount",.variable),
            ("sample.go","package main","package",.keyword),
            ("sample.rs","#[derive(Debug)]\nstruct Thing;","#[derive(Debug)]",.attribute),
            ("sample.c","#include <stdio.h>","#include",.preprocessor),
            ("sample.cpp","namespace sample {}","namespace",.keyword),
            ("sample.m","@interface Thing : NSObject","@interface",.keyword),
            ("sample.java","@Override public void run() {}","@Override",.attribute),
            ("sample.kt","fun greet() {}","greet",.function),
            ("sample.cs","using System;","using",.keyword),
            ("sample.php","<?php $item = 4;","$item",.variable),
            ("sample.sh","echo $HOME","$HOME",.variable),
            ("sample.yaml","title: demo","title",.property),
            ("sample.toml","[table]","[table]",.type),
            ("sample.html","<div class=\"value\">","div",.tag),
            ("sample.xml","<item key=\"value\"/>","item",.tag),
            ("sample.css","a { color: red; }","color",.property),
            ("sample.md","# Heading","# Heading",.heading),
            ("sample.sql","select * FROM sample","select",.keyword),
            ("Dockerfile","FROM alpine","FROM",.keyword),
            ("Makefile","target: source","target",.function)
        ]
        XCTAssertEqual(samples.count,SilicaLanguage.allCases.count)
        XCTAssertEqual(Set(samples.compactMap { SilicaLanguage(url:URL(fileURLWithPath:$0.0)) }).count,SilicaLanguage.allCases.count)
        for (path,code,fragment,kind) in samples {
            let expected = (code as NSString).range(of:fragment)
            let tokens = SourceSyntax.analyze(code,path:path).tokens
            XCTAssertTrue(tokens.contains { NSIntersectionRange($0.range,expected).length == expected.length && $0.kind == kind },
                          "\(path): \(tokens.map { ($0.kind,(code as NSString).substring(with:$0.range)) })")
            XCTAssertTrue(zip(tokens,tokens.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location },path)
        }
    }

    func testSpansOverrideRulesAndFencesUseFileGrammars() {
        let code = "func example() {\n  let value = \"// 调用(42)\" // 123\n  return\n}"
        let source = code as NSString
        let result = SourceSyntax.analyze(code,path:"remote.swift")
        for (sample,kind) in [("\"// 调用(42)\"",SourceTokenKind.string),("// 123",.comment),("return",.keyword)] {
            XCTAssertTrue(result.tokens.contains { $0.kind == kind && $0.range == source.range(of:sample) })
        }
        XCTAssertEqual(result.folds.count,1)
        let directive = SourceSyntax.fencedHighlights("FROM alpine",language:"docker")
        XCTAssertEqual(directive.first?.kind,.keyword)
        XCTAssertEqual(SourceSyntax.fencedHighlights("echo $HOME",language:"shell").last?.kind,.variable)
    }
}
