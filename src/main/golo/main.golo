module sunday

import io.vertx.core.AsyncResult
import io.vertx.core.Vertx
import io.vertx.core.http.HttpServer
import io.vertx.ext.web.Router
import io.vertx.ext.web.RoutingContext
import io.vertx.ext.web.handler.BodyHandler

import org.objectweb.asm.ClassReader
import org.objectweb.asm.util.ASMifier
import org.objectweb.asm.util.TraceClassVisitor

import java.io.File
import java.io.FileInputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.nio.charset.Charset
import java.nio.file.Files
import java.nio.file.Path
import java.util.ArrayList
import java.util.List
import java.util.UUID
import java.util.regex.Matcher
import java.util.regex.Pattern

local function _port = -> 8080
local function _java_home = -> System.getenv("JAVA_HOME")
local function _javac = -> _java_home() + "/bin/javac"
local function _javap = -> _java_home() + "/bin/javap"


function main = |args| {
  let vertx = Vertx.vertx()
  let router = Router.router(vertx)
  router: route(): handler(BodyHandler.create())

  router: post("/bytecode"): handler(^javaToByteCode)
  router: post("/asm"): handler(^javaToAsm)
  vertx
    : createHttpServer()
    : requestHandler(|httpRequest| -> router: accept(httpRequest))
    : listen(_port(), ^_onHttpServerDeploymentDone)
}

local function _onHttpServerDeploymentDone = |deploymentStatus| {
  if deploymentStatus: succeeded() {
    println("Listening on  port " + _port() + "...")
  } else {
    println("Error " + deploymentStatus: cause(): getMessage())
  }
}

local function getOrElseFalse = |params, key| {
  if params: contains(key) {
    return Boolean.parseBoolean(params: get(key))
  }
  return false
}

local function javaToByteCode = |context| {
  let code = context: getBodyAsString()
  let params = context: request(): params()
  let verbose = getOrElseFalse(params, "verbose")
  let lineNumbers = getOrElseFalse(params, "lineNumbers")
  let private = getOrElseFalse(params, "private")
  let signatures = getOrElseFalse(params, "signatures")
  let sysinfo = getOrElseFalse(params, "sysinfo")
  let constants = getOrElseFalse(params, "constants")
  let className = getFullQualifiedClassName(code)
  try {
    let tmp = Files.createTempDirectory(UUID.randomUUID(): toString()): toFile()
    compile(tmp, className, code)
    let disassembled = disassemble(
      workDir = tmp,
      className = className,
      verbose = verbose,
      lineNumbers = lineNumbers,
      private = private,
      signatures = signatures,
      sysinfo = sysinfo,
      constants = constants
    )
    tmp: delete()
    context: response(): setStatusCode(200): end(disassembled)
  } catch (e) {
    context: response(): setStatusCode(500): end(e: getMessage())
  }
}

local function javaToAsm = |context| {
  let code = context: getBodyAsString()
  let className = getFullQualifiedClassName(code)
  let tmp = Files.createTempDirectory(UUID.randomUUID(): toString()): toFile()
  try {
    compile(tmp, className, code)
    let asm = asmifier(tmp, className)
    tmp: delete()
    context: response(): setStatusCode(200): end(asm)
  } catch(e) {
    context: response(): setStatusCode(500): end(e: getMessage())
    e: printStackTrace()
  }
}
local function getFullQualifiedClassName = |code| {
  let packageName = extractPackageName(code)
  let className = extractClassName(code)
  if packageName: length() != 0 {
    return packageName + "." + className
  }
  return className
}

local function extractPackageName = |code| {
  let packagePattern = Pattern.compile("package\\s+([\\w\\.]+);")
  let packageMatcher = packagePattern: matcher(code)
  if packageMatcher: find() {
    return packageMatcher: group(1)
  }
  return ""
}

local function extractClassName = |code| {
  let classPattern = Pattern.compile("\\s*(public|private)\\s+class\\s+(\\w+)\\s+((extends\\s+\\w+)|(implements\\s+\\w+( ,\\w+)*))?\\s*\\{")
  let classMatcher = classPattern: matcher(code)
  if classMatcher: find() {
    return classMatcher: group(2)
  }
  return ""
}

local function getPackage = |fqn| {
  let lastDot = fqn: lastIndexOf(".")
  if lastDot == -1 {
    return ""
  }
  return fqn: substring(0, lastDot)
}

local function compile = |workDir, className, code| {
  let stderr = File(workDir, "javac.err")
  let packagePath = getPackage(className): replaceAll("\\.", "/")
  if packagePath: length() != 0 {
    File(workDir, packagePath): mkdirs()
  }
  let sourceRelativePath = className: replaceAll("\\.", "/") + ".java"
  let sourcePath = File(workDir, sourceRelativePath): getAbsolutePath()
  textToFile(code, sourcePath)
  let command = list[]:
    append(_javac()):
    append(sourcePath)
  let builder = ProcessBuilder():
    directory(workDir):
    redirectError(stderr):
    command(command)
  let javac = builder: start()
  javac: waitFor()
  if stderr: length() != 0 {
    raise("Compilation error " + fileToText(stderr, Charset.defaultCharset()))
  }
}

local function disassemble = |workDir, className, verbose, lineNumbers, private, signatures, sysinfo, constants| {
  let stdout = File(workDir, "javap.out")
  let stderr = File(workDir, "javap.err")
  let command = list[]: append(_javap()): append("-c")
  if verbose {
   command: add("-verbose")
  }
  if lineNumbers {
    command: add("-l")
  }
  if private {
    command: add("-private")
  }
  if signatures {
    command: add("-s")
  }
  if sysinfo {
    command: add("-sysinfo")
  }
  if constants {
    command: add("-constants")
  }
  command: add(className)
  let builder = ProcessBuilder():
    directory(workDir):
    redirectOutput(stdout):
    redirectError(stderr):
    command(command)
  let javap = builder: start()
  javap: waitFor()
  if stderr: length() != 0 {
    raise("Disassembling error " + fileToText(stderr, Charset.defaultCharset()))
  }
  return fileToText(stdout, Charset.defaultCharset())
}

local function asmifier = |workDir, className| {
  let classFile = File(workDir, className: replaceAll("\\.", "/") + ".class")
  let cr = ClassReader(FileInputStream(classFile))
  let writer = StringWriter()
  cr: accept(TraceClassVisitor(null, ASMifier(), PrintWriter(writer)), ClassReader.SKIP_DEBUG())
  return writer: toString()
}