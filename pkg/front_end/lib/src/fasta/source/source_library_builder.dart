// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.source_library_builder;

import 'package:kernel/ast.dart' show ProcedureKind;

import '../../base/resolve_relative_uri.dart' show resolveRelativeUri;

import '../../base/instrumentation.dart' show Instrumentation;

import '../../scanner/token.dart' show Token;

import '../builder/builder.dart'
    show
        Builder,
        ClassBuilder,
        ConstructorReferenceBuilder,
        FormalParameterBuilder,
        FunctionTypeBuilder,
        LibraryBuilder,
        MemberBuilder,
        MetadataBuilder,
        NamedTypeBuilder,
        PrefixBuilder,
        ProcedureBuilder,
        QualifiedName,
        Scope,
        TypeBuilder,
        TypeDeclarationBuilder,
        TypeVariableBuilder,
        Unhandled,
        UnresolvedType;

import '../combinator.dart' show Combinator;

import '../deprecated_problems.dart' show deprecated_inputError;

import '../export.dart' show Export;

import '../fasta_codes.dart'
    show
        messageExpectedUri,
        messagePartOfSelf,
        messageMemberWithSameNameAsClass,
        templateConflictsWithMember,
        templateConflictsWithSetter,
        templateCouldNotParseUri,
        templateDeferredPrefixDuplicated,
        templateDeferredPrefixDuplicatedCause,
        templateDuplicatedDefinition,
        templateMissingPartOf,
        templatePartOfLibraryNameMismatch,
        templatePartOfUriMismatch,
        templatePartOfUseUri,
        templatePartTwice;

import '../import.dart' show Import;

import '../problems.dart' show unhandled;

import 'source_loader.dart' show SourceLoader;

abstract class SourceLibraryBuilder<T extends TypeBuilder, R>
    extends LibraryBuilder<T, R> {
  static const String MALFORMED_URI_SCHEME = "org-dartlang-malformed-uri";

  final SourceLoader loader;

  final DeclarationBuilder<T> libraryDeclaration;

  final List<ConstructorReferenceBuilder> constructorReferences =
      <ConstructorReferenceBuilder>[];

  final List<SourceLibraryBuilder<T, R>> parts = <SourceLibraryBuilder<T, R>>[];

  final List<Import> imports = <Import>[];

  final List<Export> exports = <Export>[];

  final Scope importScope;

  final Uri fileUri;

  final List<List> implementationBuilders = <List<List>>[];

  /// Indicates whether type inference (and type promotion) should be disabled
  /// for this library.
  final bool disableTypeInference;

  String documentationComment;

  String name;

  String partOfName;

  Uri partOfUri;

  List<MetadataBuilder> metadata;

  /// The current declaration that is being built. When we start parsing a
  /// declaration (class, method, and so on), we don't have enough information
  /// to create a builder and this object records its members and types until,
  /// for example, [addClass] is called.
  DeclarationBuilder<T> currentDeclaration;

  bool canAddImplementationBuilders = false;

  SourceLibraryBuilder(SourceLoader loader, Uri fileUri)
      : this.fromScopes(loader, fileUri, new DeclarationBuilder<T>.library(),
            new Scope.top());

  SourceLibraryBuilder.fromScopes(
      this.loader, this.fileUri, this.libraryDeclaration, this.importScope)
      : disableTypeInference = loader.target.disableTypeInference,
        currentDeclaration = libraryDeclaration,
        super(
            fileUri, libraryDeclaration.toScope(importScope), new Scope.top());

  Uri get uri;

  bool get isPart => partOfName != null || partOfUri != null;

  List<UnresolvedType<T>> get types => libraryDeclaration.types;

  T addNamedType(Object name, List<T> arguments, int charOffset);

  T addMixinApplication(T supertype, List<T> mixins, int charOffset);

  T addType(T type, int charOffset) {
    currentDeclaration
        .addType(new UnresolvedType<T>(type, charOffset, fileUri));
    return type;
  }

  T addVoidType(int charOffset);

  ConstructorReferenceBuilder addConstructorReference(
      Object name, List<T> typeArguments, String suffix, int charOffset) {
    ConstructorReferenceBuilder ref = new ConstructorReferenceBuilder(
        name, typeArguments, suffix, this, charOffset);
    constructorReferences.add(ref);
    return ref;
  }

  void beginNestedDeclaration(String name, {bool hasMembers: true}) {
    currentDeclaration = currentDeclaration.createNested(name, hasMembers);
  }

  DeclarationBuilder<T> endNestedDeclaration(String name) {
    assert(
        (name?.startsWith(currentDeclaration.name) ??
                (name == currentDeclaration.name)) ||
            currentDeclaration.name == "operator",
        "${name} != ${currentDeclaration.name}");
    DeclarationBuilder<T> previous = currentDeclaration;
    currentDeclaration = currentDeclaration.parent;
    return previous;
  }

  bool uriIsValid(Uri uri) => uri.scheme != MALFORMED_URI_SCHEME;

  Uri resolve(Uri baseUri, String uri, int uriOffset, {isPart: false}) {
    if (uri == null) {
      addCompileTimeError(messageExpectedUri, uriOffset, this.uri);
      return new Uri(scheme: MALFORMED_URI_SCHEME);
    }
    Uri parsedUri;
    try {
      parsedUri = Uri.parse(uri);
    } on FormatException catch (e) {
      // Point to position in string indicated by the exception,
      // or to the initial quote if no position is given.
      // (Assumes the directive is using a single-line string.)
      addCompileTimeError(
          templateCouldNotParseUri.withArguments(uri, e.message),
          uriOffset + 1 + (e.offset ?? -1),
          this.uri);
      return new Uri(
          scheme: MALFORMED_URI_SCHEME, query: Uri.encodeQueryComponent(uri));
    }
    if (isPart && baseUri.scheme == "dart") {
      // Resolve using special rules for dart: URIs
      return resolveRelativeUri(baseUri, parsedUri);
    } else {
      return baseUri.resolveUri(parsedUri);
    }
  }

  void addExport(
      List<MetadataBuilder> metadata,
      String uri,
      Unhandled conditionalUris,
      List<Combinator> combinators,
      int charOffset,
      int uriOffset) {
    var exportedLibrary = loader
        .read(resolve(this.uri, uri, uriOffset), charOffset, accessor: this);
    exportedLibrary.addExporter(this, combinators, charOffset);
    exports.add(new Export(this, exportedLibrary, combinators, charOffset));
  }

  void addImport(
      List<MetadataBuilder> metadata,
      String uri,
      Unhandled conditionalUris,
      String prefix,
      List<Combinator> combinators,
      bool deferred,
      int charOffset,
      int prefixCharOffset,
      int uriOffset) {
    imports.add(new Import(
        this,
        loader.read(resolve(this.uri, uri, uriOffset), charOffset,
            accessor: this),
        deferred,
        prefix,
        combinators,
        charOffset,
        prefixCharOffset));
  }

  void addPart(List<MetadataBuilder> metadata, String uri, int charOffset) {
    Uri resolvedUri;
    Uri newFileUri;
    resolvedUri = resolve(this.uri, uri, charOffset, isPart: true);
    if (this.uri.scheme != "package") {
      newFileUri = resolve(fileUri, uri, charOffset);
    }
    parts.add(loader.read(resolvedUri, charOffset,
        fileUri: newFileUri, accessor: this));
  }

  void addPartOf(
      List<MetadataBuilder> metadata, String name, String uri, int uriOffset) {
    partOfName = name;
    if (uri != null) {
      partOfUri = resolve(this.uri, uri, uriOffset);
    }
  }

  void addClass(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      String name,
      List<TypeVariableBuilder> typeVariables,
      T supertype,
      List<T> interfaces,
      int charOffset,
      int charEndOffset,
      int supertypeOffset);

  void addNamedMixinApplication(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<TypeVariableBuilder> typeVariables,
      int modifiers,
      T mixinApplication,
      List<T> interfaces,
      int charOffset);

  void addField(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      T type,
      String name,
      int charOffset,
      Token initializerTokenForInference,
      bool hasInitializer);

  void addFields(String documentationComment, List<MetadataBuilder> metadata,
      int modifiers, T type, List<Object> fieldsInfo) {
    for (int i = 0; i < fieldsInfo.length; i += 4) {
      String name = fieldsInfo[i];
      int charOffset = fieldsInfo[i + 1];
      bool hasInitializer = fieldsInfo[i + 2] != null;
      Token initializerTokenForInference =
          type == null ? fieldsInfo[i + 2] : null;
      if (initializerTokenForInference != null) {
        Token beforeLast = fieldsInfo[i + 3];
        beforeLast.setNext(new Token.eof(beforeLast.next.offset));
      }
      addField(documentationComment, metadata, modifiers, type, name,
          charOffset, initializerTokenForInference, hasInitializer);
    }
  }

  void addProcedure(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      T returnType,
      Object name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      ProcedureKind kind,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String nativeMethodName,
      {bool isTopLevel});

  void addEnum(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<Object> constantNamesAndOffsets,
      int charOffset,
      int charEndOffset);

  void addFunctionTypeAlias(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<TypeVariableBuilder> typeVariables,
      FunctionTypeBuilder type,
      int charOffset);

  FunctionTypeBuilder addFunctionType(
      T returnType,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      int charOffset);

  void addFactoryMethod(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      ConstructorReferenceBuilder name,
      List<FormalParameterBuilder> formals,
      ConstructorReferenceBuilder redirectionTarget,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String nativeMethodName);

  FormalParameterBuilder addFormalParameter(List<MetadataBuilder> metadata,
      int modifiers, T type, String name, bool hasThis, int charOffset);

  TypeVariableBuilder addTypeVariable(String name, T bound, int charOffset);

  Builder addBuilder(String name, Builder builder, int charOffset) {
    // TODO(ahe): Set the parent correctly here. Could then change the
    // implementation of MemberBuilder.isTopLevel to test explicitly for a
    // LibraryBuilder.
    if (currentDeclaration == libraryDeclaration) {
      if (builder is MemberBuilder) {
        builder.parent = this;
      } else if (builder is TypeDeclarationBuilder) {
        builder.parent = this;
      } else if (builder is PrefixBuilder) {
        assert(builder.parent == this);
      } else {
        return unhandled(
            "${builder.runtimeType}", "addBuilder", charOffset, fileUri);
      }
    } else {
      assert(currentDeclaration.parent == libraryDeclaration);
    }
    bool isConstructor = builder is ProcedureBuilder &&
        (builder.isConstructor || builder.isFactory);
    if (!isConstructor && name == currentDeclaration.name) {
      addCompileTimeError(
          messageMemberWithSameNameAsClass, charOffset, fileUri);
    }
    Map<String, Builder> members = isConstructor
        ? currentDeclaration.constructors
        : (builder.isSetter
            ? currentDeclaration.setters
            : currentDeclaration.members);
    Builder existing = members[name];
    builder.next = existing;
    if (builder is PrefixBuilder && existing is PrefixBuilder) {
      assert(existing.next == null);
      Builder deferred;
      Builder other;
      if (builder.deferred) {
        deferred = builder;
        other = existing;
      } else if (existing.deferred) {
        deferred = existing;
        other = builder;
      }
      if (deferred != null) {
        addCompileTimeError(
            templateDeferredPrefixDuplicated.withArguments(name),
            deferred.charOffset,
            fileUri);
        addCompileTimeError(
            templateDeferredPrefixDuplicatedCause.withArguments(name),
            other.charOffset,
            fileUri);
      }
      return existing
        ..exportScope.merge(builder.exportScope,
            (String name, Builder existing, Builder member) {
          return buildAmbiguousBuilder(name, existing, member, charOffset);
        });
    } else if (isDuplicatedDefinition(existing, builder)) {
      addCompileTimeError(templateDuplicatedDefinition.withArguments(name),
          charOffset, fileUri);
    }
    return members[name] = builder;
  }

  bool isDuplicatedDefinition(Builder existing, Builder other) {
    if (existing == null) return false;
    Builder next = existing.next;
    if (next == null) {
      if (existing.isGetter && other.isSetter) return false;
      if (existing.isSetter && other.isGetter) return false;
    } else {
      if (next is ClassBuilder && !next.isMixinApplication) return true;
    }
    if (existing is ClassBuilder && other is ClassBuilder) {
      // We allow multiple mixin applications with the same name. An
      // alternative is to share these mixin applications. This situation can
      // happen if you have `class A extends Object with Mixin {}` and `class B
      // extends Object with Mixin {}` in the same library.
      return !existing.isMixinApplication || !other.isMixinApplication;
    }
    return true;
  }

  void buildBuilder(Builder builder, LibraryBuilder coreLibrary);

  R build(LibraryBuilder coreLibrary) {
    assert(implementationBuilders.isEmpty);
    canAddImplementationBuilders = true;
    forEach((String name, Builder builder) {
      do {
        buildBuilder(builder, coreLibrary);
        builder = builder.next;
      } while (builder != null);
    });
    for (List list in implementationBuilders) {
      String name = list[0];
      Builder builder = list[1];
      int charOffset = list[2];
      addBuilder(name, builder, charOffset);
      buildBuilder(builder, coreLibrary);
    }
    canAddImplementationBuilders = false;

    scope.setters.forEach((String name, Builder setter) {
      Builder member = scopeBuilder[name];
      if (member == null || !member.isField || member.isFinal) return;
      // TODO(ahe): charOffset is missing.
      addCompileTimeError(templateConflictsWithMember.withArguments(name),
          setter.charOffset, fileUri);
      addCompileTimeError(templateConflictsWithSetter.withArguments(name),
          member.charOffset, fileUri);
    });

    return null;
  }

  /// Used to add implementation builder during the call to [build] above.
  /// Currently, only anonymous mixins are using implementation builders (see
  /// [KernelMixinApplicationBuilder]
  /// (../kernel/kernel_mixin_application_builder.dart)).
  void addImplementationBuilder(String name, Builder builder, int charOffset) {
    assert(canAddImplementationBuilders, "$uri");
    implementationBuilders.add([name, builder, charOffset]);
  }

  void validatePart() {
    if (parts.isNotEmpty) {
      deprecated_inputError(fileUri, -1,
          "A file that's a part of a library can't have parts itself.");
    }
    if (exporters.isNotEmpty) {
      Export export = exporters.first;
      deprecated_inputError(
          export.fileUri, export.charOffset, "A part can't be exported.");
    }
  }

  void includeParts() {
    Set<Uri> seenParts = new Set<Uri>();
    for (SourceLibraryBuilder<T, R> part in parts.toList()) {
      if (part == this) {
        addCompileTimeError(messagePartOfSelf, -1, fileUri);
      } else if (seenParts.add(part.fileUri)) {
        includePart(part);
      } else {
        addCompileTimeError(
            templatePartTwice.withArguments(part.fileUri), -1, fileUri);
      }
    }
  }

  void includePart(SourceLibraryBuilder<T, R> part) {
    if (part.partOfUri != null) {
      if (uriIsValid(part.partOfUri) && part.partOfUri != uri) {
        // This is a warning, but the part is still included.
        addProblem(
            templatePartOfUriMismatch.withArguments(
                part.fileUri, uri, part.partOfUri),
            -1,
            fileUri);
      }
    } else if (part.partOfName != null) {
      if (name != null) {
        if (part.partOfName != name) {
          // This is a warning, but the part is still included.
          addProblem(
              templatePartOfLibraryNameMismatch.withArguments(
                  part.fileUri, name, part.partOfName),
              -1,
              fileUri);
        }
      } else {
        // This is a warning, but the part is still included.
        addProblem(
            templatePartOfUseUri.withArguments(
                part.fileUri, fileUri, part.partOfName),
            -1,
            fileUri);
      }
    } else {
      // This is an error, but the part is still included, so that
      // metadata annotations can be associated with it.
      assert(!part.isPart);
      if (uriIsValid(part.fileUri)) {
        addCompileTimeError(
            templateMissingPartOf.withArguments(part.fileUri), -1, fileUri);
      }
    }
    part.forEach((String name, Builder builder) {
      if (builder.next != null) {
        // TODO(ahe): This shouldn't be necessary as setters have been added to
        // their own scope.
        assert(builder.next.next == null);
        addBuilder(name, builder.next, builder.next.charOffset);
      }
      addBuilder(name, builder, builder.charOffset);
    });
    types.addAll(part.types);
    constructorReferences.addAll(part.constructorReferences);
    part.partOfLibrary = this;
    part.scope.becomePartOf(scope);
    // TODO(ahe): Include metadata from part?
  }

  void buildInitialScopes() {
    forEach(addToExportScope);
  }

  void addImportsToScope() {
    bool explicitCoreImport = this == loader.coreLibrary;
    for (Import import in imports) {
      if (import.imported == loader.coreLibrary) {
        explicitCoreImport = true;
      }
      import.finalizeImports(this);
    }
    if (!explicitCoreImport) {
      loader.coreLibrary.exportScope.forEach((String name, Builder member) {
        addToScope(name, member, -1, true);
      });
    }
  }

  @override
  void addToScope(String name, Builder member, int charOffset, bool isImport) {
    Map<String, Builder> map =
        member.isSetter ? importScope.setters : importScope.local;
    Builder existing = map[name];
    if (existing != null) {
      if (existing != member) {
        map[name] = buildAmbiguousBuilder(name, existing, member, charOffset,
            isImport: isImport);
      }
    } else {
      map[name] = member;
    }
  }

  /// Resolves all unresolved types in [types]. The list of types is cleared
  /// when done.
  int resolveTypes() {
    int typeCount = types.length;
    for (UnresolvedType<T> t in types) {
      t.resolveIn(scope);
    }
    types.clear();
    return typeCount;
  }

  @override
  int resolveConstructors(_) {
    int count = 0;
    forEach((String name, Builder member) {
      count += member.resolveConstructors(this);
    });
    return count;
  }

  List<TypeVariableBuilder> copyTypeVariables(
      List<TypeVariableBuilder> original);

  @override
  String get fullNameForErrors {
    // TODO(ahe): Consider if we should use relativizeUri here. The downside to
    // doing that is that this URI may be used in an error message. Ideally, we
    // should create a class that represents qualified names that we can
    // relativize when printing a message, but still store the full URI in
    // .dill files.
    return name ?? "<library '$fileUri'>";
  }

  @override
  void prepareTopLevelInference(
      SourceLibraryBuilder library, ClassBuilder currentClass) {
    forEach((String name, Builder member) {
      if (member is ClassBuilder) {
        // Classes are handled separately, in class hierarchy order.
        return;
      }
      member.prepareTopLevelInference(library, currentClass);
    });
  }

  @override
  void instrumentTopLevelInference(Instrumentation instrumentation) {
    forEach((String name, Builder member) {
      member.instrumentTopLevelInference(instrumentation);
    });
  }
}

/// Unlike [Scope], this scope is used during construction of builders to
/// ensure types and members are added to and resolved in the correct location.
class DeclarationBuilder<T extends TypeBuilder> {
  final DeclarationBuilder<T> parent;

  final Map<String, Builder> members;

  final Map<String, Builder> constructors;

  final Map<String, Builder> setters;

  final List<UnresolvedType<T>> types = <UnresolvedType<T>>[];

  String name;

  final Map<ProcedureBuilder, DeclarationBuilder<T>> factoryDeclarations;

  DeclarationBuilder(this.members, this.setters, this.constructors,
      this.factoryDeclarations, this.name, this.parent) {
    assert(name != null);
  }

  DeclarationBuilder.library()
      : this(<String, Builder>{}, <String, Builder>{}, null, null, "library",
            null);

  DeclarationBuilder createNested(String name, bool hasMembers) {
    return new DeclarationBuilder<T>(
        hasMembers ? <String, MemberBuilder>{} : null,
        hasMembers ? <String, MemberBuilder>{} : null,
        hasMembers ? <String, MemberBuilder>{} : null,
        <ProcedureBuilder, DeclarationBuilder<T>>{},
        name,
        this);
  }

  void addType(UnresolvedType<T> type) {
    types.add(type);
  }

  /// Resolves type variables in [types] and propagate other types to [parent].
  void resolveTypes(
      List<TypeVariableBuilder> typeVariables, SourceLibraryBuilder library) {
    // TODO(ahe): The input to this method, [typeVariables], shouldn't be just
    // type variables. It should be everything that's in scope, for example,
    // members (of a class) or formal parameters (of a method).
    // Also, this doesn't work well with patching.
    if (typeVariables == null) {
      // If there are no type variables in the scope, propagate our types to be
      // resolved in the parent declaration.
      factoryDeclarations.forEach((_, DeclarationBuilder<T> declaration) {
        parent.types.addAll(declaration.types);
      });
      parent.types.addAll(types);
    } else {
      factoryDeclarations.forEach(
          (ProcedureBuilder procedure, DeclarationBuilder<T> declaration) {
        assert(procedure.typeVariables.isEmpty);
        procedure.typeVariables
            .addAll(library.copyTypeVariables(typeVariables));
        DeclarationBuilder<T> savedDeclaration = library.currentDeclaration;
        library.currentDeclaration = declaration;
        for (TypeVariableBuilder tv in procedure.typeVariables) {
          NamedTypeBuilder<T, dynamic> t = procedure.returnType;
          t.arguments
              .add(library.addNamedType(tv.name, null, procedure.charOffset));
        }
        library.currentDeclaration = savedDeclaration;
        declaration.resolveTypes(procedure.typeVariables, library);
      });
      Map<String, TypeVariableBuilder> map = <String, TypeVariableBuilder>{};
      for (TypeVariableBuilder builder in typeVariables) {
        map[builder.name] = builder;
      }
      for (UnresolvedType<T> type in types) {
        Object nameOrQualified = type.builder.name;
        String name = nameOrQualified is QualifiedName
            ? nameOrQualified.prefix
            : nameOrQualified;
        TypeVariableBuilder builder;
        if (name != null) {
          builder = map[name];
        }
        if (builder == null) {
          // Since name didn't resolve in this scope, propagate it to the
          // parent declaration.
          parent.addType(type);
        } else if (nameOrQualified is QualifiedName) {
          // Attempt to use type variable as prefix.
          type.builder.bind(
              type.builder.buildInvalidType(type.charOffset, type.fileUri));
        } else {
          type.builder.bind(builder);
        }
      }
    }
    types.clear();
  }

  /// Called to register [procedure] as a factory whose types are collected in
  /// [factoryDeclaration]. Later, once the class has been built, we can
  /// synthesize type variables on the factory matching the class'.
  void addFactoryDeclaration(
      ProcedureBuilder procedure, DeclarationBuilder<T> factoryDeclaration) {
    factoryDeclarations[procedure] = factoryDeclaration;
  }

  Scope toScope(Scope parent) {
    return new Scope(members, setters, parent, name, isModifiable: false);
  }
}
