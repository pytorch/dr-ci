{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Text           as T
import qualified Data.Tree           as Tree
import           Options.Applicative
import           System.IO

import qualified Markdown


data CommandLineArgs = NewCommandLineArgs {
    buildCount    :: Int

  }


myCliParser :: Parser CommandLineArgs
myCliParser = NewCommandLineArgs
  <$> option auto (long "count"       <> value 3           <> metavar "BUILD_COUNT"
    <> help "Maximum number of failed builds to fetch from CircleCI")


mainAppCode :: CommandLineArgs -> IO ()
mainAppCode args = do

  hSetBuffering stdout LineBuffering

  putStrLn $ unwords [
      "Scanned"
    , show fetch_count
    , "builds."
    ]


  putStrLn $ T.unpack $ Markdown.bulletTree bullet_tree



  where
    bullet_tree = [
        pure "First"
      , pure "Second"
      , Tree.Node "Third" [
          Tree.Node "3a" [
            pure "3a-i"
          , pure "3a-ii"
          , pure "3a-iii"
          ]
        , pure "3b"
        ]
      , pure "Fourth"
      ]

    fetch_count = buildCount args


main :: IO ()
main = execParser opts >>= mainAppCode
  where
    opts = info (helper <*> myCliParser)
      ( fullDesc
     <> progDesc "Generate markdown text"
     <> header "markdown-dsl - Generates markdown text" )
